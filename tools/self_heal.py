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
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

import requests


REPO_ROOT = Path(__file__).resolve().parent.parent
LOG_DIR = REPO_ROOT / "gh_run_logs"
MAX_LOG_CHARS = 100_000


def env_required(name: str) -> str:
    val = os.getenv(name)
    if not val:
        raise ValueError(f"Missing required environment variable: {name}")
    return val


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
    run(["git", "commit", "-m", "Self-heal: fix pipeline"])
    run(["git", "push", "origin", branch])
    print("[INFO] Changes pushed")


def main():
    repo = env_required("GITHUB_REPOSITORY")
    run_id = env_required("GITHUB_RUN_ID")
    branch = env_required("GITHUB_REF_NAME")
    openai_key = env_required("OPENAI_API_KEY")
    repo_token = env_required("REPO_WRITE_TOKEN")

    download_logs(repo, run_id, repo_token)
    logs_text = collect_logs_text()
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
