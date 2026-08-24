# Shell Style Guide

## Mandatory Rules

- Bash only.
- Start scripts with:

```bash
set -Eeuo pipefail
IFS=$'\n\t'
```

- Resolve paths from `${BASH_SOURCE[0]}`.
- Source `scripts/lib/common.sh`.
- Use `local` for function-local variables.
- Quote expansions unless shell splitting is explicitly required.
- Prefer `printf` over `echo`.
- Fail with explicit error messages.
- Keep loops bounded.
- Avoid global firewall flushes.
- Never replace the host default route.
- Reject `lo` and interfaces carrying the host default route.
- Prefer idempotent operations.
- `setup.sh` must rollback on error.
- `cleanup.sh` must tolerate partially-created state.
- Runtime configuration belongs in `config.env`, not repetitive command-line options.

## Process Ownership

Background processes started by the project must have PID files under `state/`.

Stop policy:

1. SIGINT
2. SIGTERM if needed
3. bounded wait
4. SIGKILL only as final fallback

## Generated Files

Generated configuration, logs, PID files, and captures must not be committed.
