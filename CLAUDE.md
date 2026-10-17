# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A public composite GitHub Action that validates a domain's MTA-STS (RFC 8461) and TLS-RPT (RFC 8460) configuration from the outside. `action.yml` only installs `dig` if needed and runs `check.sh`. All logic lives in `check.sh` (bash, `dig`/`curl`/`openssl`), which also runs standalone: `./check.sh example.com`.

The check is deliberately generic. It relies only on the RFCs and makes no assumptions about how the policy is hosted or how the policy `id` is generated.

## Commands

```sh
shellcheck check.sh tests/run.sh
bash tests/run.sh          # offline fixture tests
./check.sh <domain>        # live check (needs dig, curl, openssl; on Windows run it in WSL)
```

CI (`.github/workflows/ci.yml`) runs ShellCheck, actionlint, zizmor, the fixture tests and the action itself against live domains. The `CI passed` job aggregates all jobs, and it is the only required status check in the `main` ruleset. New jobs must be added to its `needs`.

## Releases

Publish a GitHub release with a signed `vX.Y.Z` tag. `.github/workflows/release.yml` then moves the major tag (`v1`) to it. Tag rulesets block creating, updating and deleting `v*` tags for everyone except admins, and protect `v1` from deletion.

## Structure of check.sh

- Each check calls `record STATUS name message`, where STATUS is PASS, WARN, FAIL or SKIP. Checks that depend on an earlier one record SKIP instead of failing again.
- The overall result is `fail` if any check failed, `warn` if any warned, otherwise `pass`. The script writes `result` and `report` (a Markdown table) to `$GITHUB_OUTPUT` and the table to `$GITHUB_STEP_SUMMARY`. It exits 1 on `fail`, and also on `warn` when `FAIL_ON_WARNING=true`.
- Inputs come in through environment variables (`RESOLVER`, `MIN_CERT_DAYS`, `FAIL_ON_WARNING`), never through `${{ }}` interpolation in `run:`.
- All DNS lookups go through `dns_answer`/`dns_records` and are sent to `$RESOLVER`. When `MTA_STS_OFFLINE_DIR` is set, they read `dns.txt` (dig answer format) and `policy.txt` from that directory instead, and the certificate check is skipped. The fixture tests use this mode.

## Conventions

- Add a fixture under `tests/fixtures/<case>/` (`dns.txt`, `policy.txt`, `expected`) for every new check or failure path.
- `tests/fixtures/crlf-bom/policy.txt` must keep its CRLF line endings and BOM (see `.gitattributes`).
- Actions are pinned by commit SHA with a version comment (the repo enforces SHA pinning) and updated by Renovate. Workflows set `permissions: {}` at the top level, give each job only the permissions it needs, and set `timeout-minutes` and `persist-credentials: false`.
- Commit messages follow Conventional Commits. `main` only accepts signed, squash-merged PRs.
- `.editorconfig`: LF line endings, 2-space indent, UTF-8.
