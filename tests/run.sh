#!/usr/bin/env bash
# Runs check.sh in offline mode against every fixture in tests/fixtures and compares the result
# with the fixture's `expected` file (pass, warn or fail).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failures=0

for dir in "$root"/tests/fixtures/*/; do
  name="$(basename "$dir")"
  expected="$(tr -d '[:space:]' <"$dir/expected")"
  output_file="$(mktemp)"
  log="$(MTA_STS_OFFLINE_DIR="$dir" GITHUB_OUTPUT="$output_file" GITHUB_STEP_SUMMARY="" \
    bash "$root/check.sh" example.com 2>&1)" || true
  actual="$(sed -n 's/^result=//p' "$output_file")"
  rm -f "$output_file"
  if [[ "$actual" == "$expected" ]]; then
    echo "ok   ${name} (${actual})"
  else
    echo "FAIL ${name}: expected ${expected}, got ${actual:-nothing}"
    while IFS= read -r line; do
      echo "     ${line}"
    done <<<"$log"
    failures=$((failures + 1))
  fi
done

if ((failures > 0)); then
  echo "${failures} fixture(s) failed."
  exit 1
fi
