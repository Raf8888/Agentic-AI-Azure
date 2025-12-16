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
        sys.stderr.write(f"[ERROR] Missing required environment variable: {name}\n")
        sys.exit(1)
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
    LOG_DIR.exists() and shutil.rmtree(LOG_DIR)
    LOG_DIR.mkdir(parents=True, exist_ok=True)

    url = f"https://api.github.com/repos/{repo}/actions/runs/{run_id}/logs"
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/zip",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    resp = requests.get(url, headers=headers, timeout=60)
    if resp.status_code != 200:
        sys.stderr.write(f"[ERROR] Failed to download logs ({resp.status_code}): {resp.text}\n")
        sys.exit(1)

    with zipfile.ZipFile(io.BytesIO(resp.content)) as zf:
        zf.extractall(LOG_DIR)


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
        ".github/workflows/azure-fgt-lab.yml",
        "scripts/01_hub_fgt_deploy.sh",
        "scripts/02_spoke_and_peering.sh",
        "scripts/03_fgt_min_config_snippet.sh",
        "scripts/04_validate_env.sh",
    ]
    content_parts = [
        "You are an autonomous CI fixer. Analyze logs and propose file replacements.",
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
        sys.stderr.write(f"[ERROR] OpenAI API failed ({resp.status_code}): {resp.text}\n")
        sys.exit(1)
    data = resp.json()
    try:
        return data["choices"][0]["message"]["content"]
    except Exception as exc:
        sys.stderr.write(f"[ERROR] Unexpected OpenAI response structure: {exc}\n{json.dumps(data, indent=2)}\n")
        sys.exit(1)


def parse_patches(content: str):
    patches = []
    lines = content.splitlines()
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
                sys.stderr.write(f"[ERROR] Missing terminator for file {path}\n")
                sys.exit(1)
            patches.append((path, "\n".join(buf).rstrip("\n") + "\n"))
        i += 1
    if not patches:
        sys.stderr.write("[ERROR] No patches parsed from OpenAI response\n")
        sys.exit(1)
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
    apply_patches(patches)
    maybe_commit_and_push(branch)


if __name__ == "__main__":
    main()
