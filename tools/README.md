# Self-heal helper

This folder contains a self-healing helper for the GitHub Actions pipeline:

- `tools/self_heal.py` runs after a failed workflow (job `self_heal`). It downloads the current run logs, packages relevant repo files, asks OpenAI for fixes, applies returned file replacements, commits, and pushes back to the same branch.
- `tools/create_sp_and_print_json.ps1` is a helper to create a service principal JSON for secrets.

Required secrets (in GitHub Actions):
- `OPENAI_API_KEY` – API key for the OpenAI Chat Completions endpoint.
- `REPO_WRITE_TOKEN` – token with permission to push to the repository and read workflow logs.

Disable the self-heal job by commenting out or removing the `self_heal` job block in `.github/workflows/azure-fgt-lab.yml`.
