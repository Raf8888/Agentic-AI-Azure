<!-- Copilot / AI agent instructions for contributors and automation agents -->
# Project-specific Copilot instructions

This repository automates a FortiGate hub-spoke lab on Azure and includes a small "infrastructure agent" example. Use these instructions to make AI coding agents productive quickly.

- **Big picture:** This repo deploys a hub VNet with a FortiGate BYOL VM (hub) and a spoke VNet with a workload VM (spoke). Routing is implemented by an Azure route table in the spoke that forwards 0.0.0.0/0 to the FortiGate LAN IP (10.100.1.4). The primary automation is in `scripts/` and orchestrated by the GitHub Actions workflow `.github/workflows/azure-fgt-lab.yml`.

- **Key files to read first:**
  - `README.md` — high-level overview and GitHub Actions usage.
  - `scripts/01_hub_fgt_deploy.sh`, `scripts/02_spoke_and_peering.sh`, `scripts/03_fgt_min_config_snippet.sh`, `scripts/04_validate_env.sh` — the actual deployment and validation steps.
  - `azure-fgt-lab-architecture.md` — topology and design rationale.
  - `agentic_infra_agent.py`, `run_agent.sh`, `env_filled.env`, `setup_instructions.txt` — the local agent example and environment/config guidance.

- **Patterns & conventions used in scripts:**
  - All Bash scripts use `set -euo pipefail` and `--only-show-errors` for `az` commands; they are intentionally quiet and idempotent where possible.
  - Defaults are embedded at the top of scripts (e.g. `AZURE_REGION=${AZURE_REGION:-westeurope}`) — modify environment variables rather than editing core logic.
  - Sensitive values (passwords, keys) are present as lab defaults in scripts for convenience; do NOT commit real secrets — use GitHub Secrets or `.env` for local runs.

- **Developer workflows (explicit commands):**
  - To run the full lab via CI: push to `main` or trigger `.github/workflows/azure-fgt-lab.yml` from Actions (see `README.md`).
  - To run manually on a machine with Azure CLI:
    1. Ensure `az` and `terraform` are installed and logged in (or set `AZURE_CREDENTIALS` secret for CI).
    2. Run in order on a shell with environment variables set:
       - `bash scripts/01_hub_fgt_deploy.sh`
       - `bash scripts/02_spoke_and_peering.sh`
       - `bash scripts/03_fgt_min_config_snippet.sh`
       - `bash scripts/04_validate_env.sh`
  - The `scripts/*` scripts are non-interactive and redirect most output to `/dev/null`; for debugging, run them interactively (remove `>/dev/null`) or run the underlying `az` commands manually.

- **Agent-specific guidance (`agentic_infra_agent.py`):**
  - Requires `agent-framework` Python package and Python 3.9+. Install on the VM with `pip install agent-framework`.
  - Optional integration with Palo Alto devices uses `pan-os-python` (`pip install pan-os-python`). The script degrades gracefully if this package is missing.
  - Registered tool functions (exposed to the LLM via `@ai_function`):
    - `terraform_apply(directory: str, auto_approve: bool=False)` — runs `terraform init`, `plan`, and `apply` in `directory`.
    - `azure_cli(command: str)` — runs `az <command>`; provide the arguments without the leading `az`.
    - `paloalto_create_address_object(...)` — uses panos SDK to create an address object (requires credentials and SDK).
  - Environment variables the agent expects: `OPENAI_API_TYPE`, `OPENAI_API_KEY`, `OPENAI_API_BASE`, `OPENAI_DEPLOYMENT_NAME` (see `env_filled.env` and `setup_instructions.txt`).
  - Example REPL prompts (what the agent expects):
    - `terraform_apply /home/azureuser/my-terraform-project` — invoke plan + apply (use `auto_approve` if you want non-interactive apply).
    - `azure_cli group list -o table` — list resource groups (omit the leading `az`).
    - `paloalto_create_address_object "InternalServer" "192.168.1.10" "FirewallAddressGroup"` — example for creating a firewall address object (SDK required).

- **Safety and diagnostics:**
  - `run_terraform` and `run_azure_cli` return clear error strings when binaries are missing (e.g. "Terraform binary not found"). Use those messages to detect missing dependencies.
  - Scripts assume the default region `westeurope`; prefer setting `AZURE_REGION` env var when testing other regions.
  - Secrets: CI uses `AZURE_CREDENTIALS` repository secret (service principal JSON). Locally use a `.env` (see `env_filled.env`) and `run_agent.sh` to load it.

- **When editing code or adding features, reference these examples:**
  - To add a new Azure operation, follow the `azure_cli` wrapper pattern (string -> `az` subprocess) and register as an `@ai_function`.
  - To add a new Terraform tooling helper, mirror `run_terraform` (check PATH, `terraform init`, `plan` to a file, then `apply`).

If anything here is unclear or you want me to include examples for other files (tests, workflow YAML, or a safer `azure_cli` wrapper), tell me which area to expand and I will iterate.
