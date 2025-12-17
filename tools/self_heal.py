#!/usr/bin/env python3
"""
Self-healing helper:
- Downloads current run logs
- Sends logs + key repo files to OpenAI
- Applies returned file contents
- Commits and pushes changes back to the current branch

Expected OpenAI response format:

FILE: relative/path
<full new content>
<<<END_FILE
"""

import io
import json
import os
import re
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path
from typing import Optional

import requests


REPO_ROOT = Path(__file__).resolve().parent.parent
LOG_DIR = REPO_ROOT / "gh_run_logs"
MAX_LOG_CHARS = 100_000


def env_required(name: str) -> str:
    val = os.getenv(name)
    if not val:
        raise ValueError(f"Missing required environment variable: {name}")
    return val


def env_optional(name: str) -> Optional[str]:
    val = os.getenv(name)
    return val if val else None


def run(cmd, check=True, capture_output=False, env=None):
    return subprocess.run(
        cmd,
        check=check,
        capture_output=capture_output,
        text=True,
        env=env,
    )


def download_logs(repo: str, run_id: str, token: str) -> None:
    if LOG_DIR.exists():
        shutil.rmtree(LOG_DIR)
    LOG_DIR.mkdir(parents=True, exist_ok=True)

    url = f"https://api.github.com/repos/{repo}/actions/runs/{run_id}/logs"
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    }

    resp = requests.get(url, headers=headers, timeout=60, allow_redirects=False)
    if resp.status_code in (301, 302, 303, 307, 308) and resp.headers.get("Location"):
        zip_url = resp.headers["Location"]
        zip_resp = requests.get(zip_url, timeout=60)
        if zip_resp.status_code == 200:
            try:
                with zipfile.ZipFile(io.BytesIO(zip_resp.content)) as zf:
                    zf.extractall(LOG_DIR)
                return
            except Exception:
                pass
        (LOG_DIR / "logs_download_failed.txt").write_text(
            f"Redirected logs download failed: {zip_resp.status_code}\n{zip_resp.text[:2000]}\n"
        )
        return

    if resp.status_code == 200:
        try:
            with zipfile.ZipFile(io.BytesIO(resp.content)) as zf:
                zf.extractall(LOG_DIR)
            return
        except Exception:
            pass

    (LOG_DIR / "logs_unavailable.txt").write_text(
        f"Logs endpoint did not return zip. status={resp.status_code}\n{resp.text[:2000]}\n"
    )


def collect_logs_text() -> str:
    parts = []
    for path in sorted(LOG_DIR.rglob("*")):
        if path.is_file():
            try:
                parts.append(f"--- {path.relative_to(LOG_DIR)} ---\n{path.read_text(errors='ignore')}\n")
            except Exception:
                continue
    combined = "\n".join(parts)
    if len(combined) > MAX_LOG_CHARS:
        combined = combined[-MAX_LOG_CHARS:]
    return combined


def read_optional_file(rel_path: str) -> str:
    path = REPO_ROOT / rel_path
    if path.exists():
        return path.read_text()
    return ""


def try_builtin_fixes(logs: str) -> bool:
    """
    Apply small deterministic fixes without OpenAI when we recognize common failures.
    Returns True if any file was changed.
    """
    changed = False
    # Always apply safe static fixes if patterns exist in the repo (even if logs download fails).
    changed |= fix_common_ps_uint32_hex_overflow()
    if "The property 'addressPrefixes' cannot be found on this object" in logs or "addressPrefixes cannot be found" in logs:
        changed |= fix_common_ps_address_prefixes()
    if (
        "Cannot convert value \"-1\" to type \"System.UInt32\"" in logs
        or "Invalid CIDR format" in logs
        or "Invalid prefix length in CIDR" in logs
        or "Convert-CidrToRange" in logs
    ):
        changed |= fix_common_ps_cidr_validation()
    return changed


def fix_common_ps_uint32_hex_overflow() -> bool:
    """
    Fix PowerShell overflow: in pwsh, 0xFFFFFFFF is an Int32 -1; casting [uint32]0xFFFFFFFF throws.
    Replace any occurrences of [uint32]0xFFFFFFFF with [uint32]::MaxValue.
    """
    path = REPO_ROOT / "tools" / "common.ps1"
    if not path.exists():
        return False

    text = path.read_text()
    original = text
    text = re.sub(r"\[uint32\]\s*0xFFFFFFFF", "[uint32]::MaxValue", text, flags=re.IGNORECASE)

    if text != original:
        path.write_text(text)
        print("[BUILTIN_FIX] Replaced [uint32]0xFFFFFFFF with [uint32]::MaxValue in tools/common.ps1")
        return True
    return False


def fix_common_ps_address_prefixes() -> bool:
    """
    Fix StrictMode failures when Azure CLI JSON doesn't include addressPrefixes.
    Converts direct property access to guarded access via Get-SubnetAddressPrefixes helper.
    """
    path = REPO_ROOT / "tools" / "common.ps1"
    if not path.exists():
        return False

    text = path.read_text()
    original = text

    helper = r"""function Get-SubnetAddressPrefixes {
  param([Parameter(Mandatory)] $SubnetObj)

  $prefixes = @()
  if ($null -eq $SubnetObj) { return @() }

  if ($null -ne $SubnetObj.PSObject.Properties['addressPrefix']) {
    $prefixes += @($SubnetObj.addressPrefix)
  }
  if ($null -ne $SubnetObj.PSObject.Properties['addressPrefixes']) {
    $prefixes += @($SubnetObj.addressPrefixes)
  }

  return @(
    $prefixes |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      ForEach-Object { $_.ToString().Trim() }
  )
}
"""

    if "function Get-SubnetAddressPrefixes" not in text:
        marker = "function Test-CidrOverlap {"
        idx = text.find(marker)
        if idx != -1:
            text = text[:idx] + helper + "\n" + text[idx:]

    text = text.replace(
        "Prefixes = @($_.addressPrefix) + @($_.addressPrefixes)",
        "Prefixes = (Get-SubnetAddressPrefixes -SubnetObj $_)",
    )
    text = text.replace(
        "$existingPrefixes = @($existing.addressPrefix) + @($existing.addressPrefixes)",
        "$existingPrefixes = Get-SubnetAddressPrefixes -SubnetObj $existing",
    )

    if text != original:
        path.write_text(text)
        print("[BUILTIN_FIX] Patched tools/common.ps1 for addressPrefixes StrictMode")
        return True
    return False


def fix_common_ps_cidr_validation() -> bool:
    """
    Add input validation to Convert-CidrToRange to avoid cryptic UInt32 conversion errors.
    """
    path = REPO_ROOT / "tools" / "common.ps1"
    if not path.exists():
        return False

    text = path.read_text()
    original = text

    marker = "function Convert-CidrToRange {"
    idx = text.find(marker)
    if idx == -1:
        return False

    # If validation already present, skip.
    if "Invalid CIDR format" in text or "Invalid prefix length in CIDR" in text:
        return False

    # Insert validation right after the param line.
    lines = text.splitlines(True)
    out = []
    in_target = False
    inserted = False
    for line in lines:
        out.append(line)
        if line.strip() == marker.strip():
            in_target = True
            continue
        if in_target and (not inserted) and line.strip().startswith("param("):
            # After param line
            out.append("  if ([string]::IsNullOrWhiteSpace($Cidr)) {\n")
            out.append("    throw \"Invalid CIDR format: <empty>\"\n")
            out.append("  }\n")
            out.append("  $Cidr = $Cidr.Trim()\n")
            out.append("  if (-not ($Cidr -match '^\\d{1,3}(\\.\\d{1,3}){3}/\\d{1,2}$')) {\n")
            out.append("    throw \"Invalid CIDR format: $Cidr\"\n")
            out.append("  }\n")
            inserted = True
            continue
        if in_target and inserted and line.strip().startswith("$prefix ="):
            # keep existing parsing; we'll validate after prefix parse
            continue

    text2 = "".join(out)

    # Add prefix-range and IP validation if missing by conservative string replace.
    if "$prefix = [int]$parts[1]" in text2 and "Invalid prefix length in CIDR" not in text2:
        text2 = text2.replace(
            "$prefix = [int]$parts[1]\n  $ipInt = Convert-IPv4ToUInt32 -Ip $ip\n",
            "$prefix = [int]$parts[1]\n  if ($prefix -lt 0 -or $prefix -gt 32) {\n    throw \"Invalid prefix length in CIDR: $Cidr\"\n  }\n  try {\n    [void][System.Net.IPAddress]::Parse($ip)\n  } catch {\n    throw \"Invalid IP in CIDR: $Cidr\"\n  }\n  $ipInt = Convert-IPv4ToUInt32 -Ip $ip\n",
        )

    if text2 != original:
        path.write_text(text2)
        print("[BUILTIN_FIX] Patched tools/common.ps1 Convert-CidrToRange validation")
        return True
    return False


def build_prompt(logs: str) -> str:
    files_to_include = [
        "config/lab.json",
        ".github/workflows/azure-fgt-lab.yml",
        "tools/common.ps1",
        "scripts/01_hub_fgt_deploy.sh",
        "scripts/02_spoke_routing.sh",
        "scripts/stage1.ps1",
        "scripts/stage2.ps1",
        "scripts/stage3.ps1",
        "scripts/03_fgt_min_config_snippet.sh",
        "scripts/04_validate_env.sh",
    ]
    content_parts = [
        "You are an autonomous CI fixer. Analyze logs and propose file replacements.",
        "Primary goal: make the workflow pass end-to-end with idempotent Azure CLI scripts.",
        "If you see subnet overlap errors (e.g., snet-fgt-lan 10.100.1.0/24 overlaps), DO NOT hardcode a single new /24; implement deterministic non-overlapping subnet selection or reuse an existing subnet using Azure CLI queries.",
        "Return ONLY patches in this exact format (no prose):",
        "FILE: relative/path",
        "<full new content>",
        "<<<END_FILE",
        "",
        "Logs (truncated):",
        logs,
        "",
        "Files:",
    ]

    for rel in files_to_include:
        text = read_optional_file(rel)
        if text:
            content_parts.append(f"FILE_CONTENT: {rel}\n{text}")

    return "\n".join(content_parts)


def call_openai(api_key: str, prompt: str) -> str:
    url = "https://api.openai.com/v1/chat/completions"
    payload = {
        "model": "gpt-4.1-mini",
        "temperature": 0.1,
        "messages": [
            {"role": "system", "content": "You are a precise CI fixer. Respond only with file replacements in the specified format."},
            {"role": "user", "content": prompt},
        ],
    }
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
    }
    resp = requests.post(url, headers=headers, json=payload, timeout=60)
    if resp.status_code != 200:
        raise RuntimeError(f"OpenAI API failed ({resp.status_code}): {resp.text}")
    data = resp.json()
    try:
        return data["choices"][0]["message"]["content"]
    except Exception as exc:
        raise RuntimeError(f"Unexpected OpenAI response structure: {exc}\n{json.dumps(data, indent=2)}")


def parse_patches(content: str):
    patches = []
    # Tolerate markdown fences / leading chatter; only trust explicit FILE blocks.
    cleaned = content.replace("```", "")
    lines = cleaned.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        if line.startswith("FILE:"):
            path = line.split("FILE:", 1)[1].strip()
            i += 1
            buf = []
            while i < len(lines) and lines[i].strip() != "<<<END_FILE":
                buf.append(lines[i])
                i += 1
            if i == len(lines):
                raise RuntimeError(f"Missing terminator for file {path}")
            patches.append((path, "\n".join(buf).rstrip("\n") + "\n"))
        i += 1
    return patches


def apply_patches(patches):
    for rel_path, content in patches:
        target = (REPO_ROOT / rel_path).resolve()
        if REPO_ROOT not in target.parents and target != REPO_ROOT:
            sys.stderr.write(f"[WARN] Skipping path outside repo: {rel_path}\n")
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content)
        print(f"[APPLIED] {rel_path}")


def maybe_commit_and_push(branch: str):
    # Never commit downloaded logs
    if LOG_DIR.exists():
        shutil.rmtree(LOG_DIR)

    status = run(["git", "status", "--porcelain"], capture_output=True).stdout.strip()
    if not status:
        print("[INFO] No changes to commit")
        return
    run(["git", "config", "user.name", "agentic-bot"])
    run(["git", "config", "user.email", "agentic-bot@local"])
    run(["git", "add", "."])
    commit = run(["git", "commit", "-m", "Self-heal: fix pipeline"], capture_output=True)
    if commit.stdout:
        print(commit.stdout.strip())
    if commit.stderr:
        print(commit.stderr.strip())
    push = run(["git", "push", "origin", branch], capture_output=True)
    if push.stdout:
        print(push.stdout.strip())
    if push.stderr:
        print(push.stderr.strip())
    print("[INFO] Changes pushed")


def main():
    repo = env_required("GITHUB_REPOSITORY")
    run_id = env_required("GITHUB_RUN_ID")
    branch = env_required("GITHUB_REF_NAME")
    openai_key = env_optional("OPENAI_API_KEY")
    repo_token = env_optional("REPO_WRITE_TOKEN")

    print(f"[SELF_HEAL] repo={repo} run_id={run_id} branch={branch}")

    if not repo_token:
        print("[SELF_HEAL] Missing REPO_WRITE_TOKEN; cannot download logs or push fixes.")
        return

    download_logs(repo, run_id, repo_token)
    logs_text = collect_logs_text()

    # Try deterministic local fixes first (no OpenAI required)
    if try_builtin_fixes(logs_text):
        maybe_commit_and_push(branch)
        return

    if not openai_key:
        print("[SELF_HEAL] Missing OPENAI_API_KEY; no OpenAI-based fixes will be attempted.")
        return

    prompt = build_prompt(logs_text)
    response = call_openai(openai_key, prompt)
    patches = parse_patches(response)
    if not patches:
        sys.stderr.write("[SELF_HEAL_WARN] OpenAI response contained no FILE blocks; no changes applied.\n")
        return
    apply_patches(patches)
    maybe_commit_and_push(branch)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        sys.stderr.write(f"[SELF_HEAL_WARN] {exc}\n")
    sys.exit(0)
