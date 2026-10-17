#!/usr/bin/env bash
# Runs check.sh in offline mode against every fixture in tests/fixtures and compares the result
# with the fixture's `expected` file: pass, warn or fail, or error for rejected input (exit code 2).
#
# Optional fixture files:
#   domain           the domain to check (default: example.com)
#   resolver         the RESOLVER to use (default: unset)
#   expected-output  lines that must each appear verbatim in the console output or the Markdown report
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failures=0

for dir in "$root"/tests/fixtures/*/; do
  name="$(basename "$dir")"
  expected="$(tr -d '[:space:]' <"$dir/expected")"
  domain="example.com"
  [[ -f "$dir/domain" ]] && domain="$(<"$dir/domain")"
  resolver=""
  [[ -f "$dir/resolver" ]] && resolver="$(<"$dir/resolver")"
  output_file="$(mktemp)"
  status=0
  log="$(MTA_STS_OFFLINE_DIR="$dir" RESOLVER="$resolver" GITHUB_OUTPUT="$output_file" GITHUB_STEP_SUMMARY="" \
    bash "$root/check.sh" "$domain" 2>&1)" || status=$?
  actual="$(sed -n 's/^result=//p' "$output_file")"
  output="${log}"$'\n'"$(<"$output_file")"
  rm -f "$output_file"
  [[ "$expected" == error && "$status" == 2 && -z "$actual" ]] && actual=error

  problems=()
  [[ "$actual" == "$expected" ]] || problems+=("expected ${expected}, got ${actual:-nothing} (exit code ${status})")
  if [[ -f "$dir/expected-output" ]]; then
    while IFS= read -r line; do
      [[ -z "$line" || "$output" == *"$line"* ]] || problems+=("missing output: ${line}")
    done <"$dir/expected-output"
  fi

  if ((${#problems[@]} == 0)); then
    echo "ok   ${name} (${actual})"
  else
    echo "FAIL ${name}"
    for problem in "${problems[@]}"; do
      echo "     ${problem}"
    done
    while IFS= read -r line; do
      echo "     | ${line}"
    done <<<"$output"
    failures=$((failures + 1))
  fi
done

if ((failures > 0)); then
  echo "${failures} fixture(s) failed."
  exit 1
fi
