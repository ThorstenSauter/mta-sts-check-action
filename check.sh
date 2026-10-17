#!/usr/bin/env bash
# Validates the MTA-STS (RFC 8461) and TLS-RPT (RFC 8460) configuration of a domain from the outside,
# the way a sending MTA sees it.
#
# Usage: check.sh <domain>
#
# Environment:
#   RESOLVER         DNS server to query (default: 1.1.1.1)
#   MIN_CERT_DAYS    Warn when the policy host's certificate expires within this many days (default: 14)
#   FAIL_ON_WARNING  Exit non-zero on warnings, too (default: false)
#   MTA_STS_OFFLINE_DIR
#                    Test mode: read DNS answers from <dir>/dns.txt (dig answer format) and the policy
#                    from <dir>/policy.txt instead of querying the network. The certificate check is skipped.
#                    action.yml always clears it, so it can't leak in from a workflow's environment.
set -euo pipefail

domain="${1:-${DOMAIN:-}}"
domain="${domain%.}"
domain="${domain,,}"
resolver="${RESOLVER:-1.1.1.1}"
resolver="${resolver,,}"
min_cert_days="${MIN_CERT_DAYS:-14}"
fail_on_warning="${FAIL_ON_WARNING:-false}"
offline_dir="${MTA_STS_OFFLINE_DIR:-}"

# Policies are a few hundred bytes. Anything bigger is refused, so a hostile server can't fill the disk or the report.
max_policy_bytes=65536
# Untrusted values (DNS records, policy lines, server responses) are shortened to this many characters in messages.
max_value_length=200
# At most this many policy errors are listed.
max_errors=5

hostname_re='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'
ipv4_re='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
ipv6_re='^[0-9a-f]*:[0-9a-f:.]*$'

if [[ -z "$domain" ]]; then
  echo "Usage: $0 <domain>" >&2
  exit 2
fi
if [[ ! "$domain" =~ $hostname_re ]] || ((${#domain} > 253)); then
  echo "Invalid domain '${domain:0:$max_value_length}': expected a hostname like example.com." >&2
  exit 2
fi
if [[ ! "$resolver" =~ $ipv4_re && ! "$resolver" =~ $ipv6_re && ! "$resolver" =~ $hostname_re ]]; then
  echo "Invalid resolver '${resolver:0:$max_value_length}': expected an IP address or a hostname." >&2
  exit 2
fi
if [[ ! "$min_cert_days" =~ ^[0-9]{1,5}$ ]]; then
  echo "MIN_CERT_DAYS must be a non-negative integer, got '${min_cert_days:0:$max_value_length}'." >&2
  exit 2
fi

policy_host="mta-sts.${domain}"
policy_url="https://${policy_host}/.well-known/mta-sts.txt"

# Shortens an untrusted value for use in a message.
clip() {
  local value="$1"
  if ((${#value} > max_value_length)); then
    printf '%s…' "${value:0:$max_value_length}"
  else
    printf '%s' "$value"
  fi
}

# Results as "STATUS|check|message" lines. STATUS is PASS, WARN, FAIL or SKIP.
results=()
record() {
  results+=("$1|$2|$3")
  printf '%-4s  %-24s  %s\n' "$1" "$2" "$3"
}

# Prints the answer section of a DNS query. Returns 1 if the lookup itself failed (timeout, SERVFAIL, ...).
dns_answer() {
  local name="$1" type="$2" out status
  if [[ -n "$offline_dir" ]]; then
    awk -v name="${name,,}." 'tolower($1) == name' "$offline_dir/dns.txt"
    return
  fi
  # -r ignores ~/.digrc. TCP makes spoofed answers harder than UDP does.
  out=$(dig -r "@$resolver" "$name" "$type" +tcp +noall +answer +comments +time=5 +tries=2) || return 1
  status=$(grep -oE 'status: [A-Z]+' <<<"$out" | head -n 1 | cut -d ' ' -f 2)
  [[ "$status" == NOERROR || "$status" == NXDOMAIN ]] || return 1
  grep -v '^;' <<<"$out" || true
}

# Prints the record data of all records of the given type, one per line. CNAMEs are followed by the resolver.
dns_records() {
  local answer
  answer=$(dns_answer "$1" "$2") || return 1
  awk -v type="$2" '$4 == type {
    sub(/^[^ \t]+[ \t]+[^ \t]+[ \t]+[^ \t]+[ \t]+[^ \t]+[ \t]+/, "")
    print
  }' <<<"$answer"
}

# Prints TXT records as plain strings, joining multi-string records.
txt_records() {
  local records
  records=$(dns_records "$1" TXT) || return 1
  sed -E 's/"[[:space:]]+"//g; s/^"//; s/"$//' <<<"$records"
}

join_by() {
  local separator="$1" out=""
  shift
  for item in "$@"; do
    out+="${out:+$separator}${item}"
  done
  printf '%s' "$out"
}

# Joins policy errors, listing at most $max_errors of them.
join_errors() {
  local count=$#
  if ((count > max_errors)); then
    printf '%s; and %d more' "$(join_by '; ' "${@:1:max_errors}")" $((count - max_errors))
  else
    join_by '; ' "$@"
  fi
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Returns 0 if the MX host matches the policy mx pattern (RFC 8461 section 4.1).
mx_matches() {
  local host="${1,,}" pattern="${2,,}" suffix prefix
  host="${host%.}"
  pattern="${pattern%.}"
  if [[ "$pattern" == \*.* ]]; then
    suffix="${pattern#\*.}"
    [[ "$host" == *."$suffix" ]] || return 1
    prefix="${host%."$suffix"}"
    [[ -n "$prefix" && "$prefix" != *.* ]]
  else
    [[ "$host" == "$pattern" ]]
  fi
}

# 1. _mta-sts TXT record
check="_mta-sts TXT record"
if ! records=$(txt_records "_mta-sts.${domain}"); then
  record FAIL "$check" "DNS lookup of _mta-sts.${domain} failed (resolver ${resolver})."
else
  sts_records=$(grep -E '^v=STSv1[[:space:]]*;' <<<"$records" || true)
  count=$(grep -c . <<<"$sts_records" || true)
  if ((count == 0)); then
    record FAIL "$check" "No record starting with 'v=STSv1;' found at _mta-sts.${domain}."
  elif ((count > 1)); then
    record FAIL "$check" "Found ${count} STSv1 records; senders ignore the policy unless there is exactly one."
  else
    id=$(grep -oE '(^|;)[[:space:]]*id=[^;]*' <<<"$sts_records" | head -n 1 | sed -E 's/.*id=//')
    id=$(trim "$id")
    if [[ -z "$id" ]]; then
      record FAIL "$check" "Record has no 'id' field: $(clip "$sts_records")"
    elif [[ ! "$id" =~ ^[A-Za-z0-9]{1,32}$ ]]; then
      record FAIL "$check" "Invalid id '$(clip "$id")': it must be 1-32 alphanumeric characters."
    else
      record PASS "$check" "$(clip "$sts_records")"
    fi
  fi
fi

# 2. _smtp._tls TXT record (TLS-RPT)
check="_smtp._tls TXT record"
if ! records=$(txt_records "_smtp._tls.${domain}"); then
  record FAIL "$check" "DNS lookup of _smtp._tls.${domain} failed (resolver ${resolver})."
else
  rpt_records=$(grep -E '^v=TLSRPTv1[[:space:]]*;' <<<"$records" || true)
  count=$(grep -c . <<<"$rpt_records" || true)
  if ((count == 0)); then
    record WARN "$check" "No TLS-RPT record found; you won't receive reports about failed TLS connections."
  elif ((count > 1)); then
    record FAIL "$check" "Found ${count} TLSRPTv1 records; senders ignore TLS-RPT unless there is exactly one."
  else
    rua=$(grep -oE '(^|;)[[:space:]]*rua=[^;]*' <<<"$rpt_records" | head -n 1 | sed -E 's/.*rua=//')
    if [[ -z "$(trim "$rua")" ]]; then
      record FAIL "$check" "Record has no 'rua' field: $(clip "$rpt_records")"
    else
      invalid=()
      IFS=',' read -ra uris <<<"$rua"
      for uri in "${uris[@]}"; do
        uri=$(trim "$uri")
        [[ "$uri" =~ ^(mailto:[^[:space:]]+@[^[:space:]]+|https://[^[:space:]]+)$ ]] || invalid+=("'$(clip "$uri")'")
      done
      if ((${#invalid[@]} > 0)); then
        record FAIL "$check" "Invalid rua URI(s) $(clip "${invalid[*]}"): only mailto: and https: are allowed."
      else
        record PASS "$check" "$(clip "$rpt_records")"
      fi
    fi
  fi
fi

# 3. Policy host resolves
check="Policy host DNS"
host_ok=false
if a_records=$(dns_records "$policy_host" A) && aaaa_records=$(dns_records "$policy_host" AAAA); then
  addresses=$(printf '%s\n%s\n' "$a_records" "$aaaa_records" | grep . || true)
else
  addresses="lookup failed"
fi
if [[ "$addresses" == "lookup failed" ]]; then
  record FAIL "$check" "DNS lookup of ${policy_host} failed (resolver ${resolver})."
elif [[ -z "$addresses" ]]; then
  record FAIL "$check" "${policy_host} has no A or AAAA record."
else
  host_ok=true
  record PASS "$check" "${policy_host} resolves to $(clip "$(paste -sd ' ' <<<"$addresses")")."
fi

# 4. Policy file over HTTPS
check="Policy file"
policy=""
policy_ok=false
body_file=$(mktemp)
trap 'rm -f "$body_file"' EXIT
fetched=false
if [[ -n "$offline_dir" ]]; then
  cp "$offline_dir/policy.txt" "$body_file"
  fetched=true
  fetch_message="Read from ${offline_dir}/policy.txt (offline mode)."
elif [[ "$host_ok" != true ]]; then
  record SKIP "$check" "Skipped because ${policy_host} does not resolve."
else
  # -q ignores ~/.curlrc. Redirects are not followed on purpose: RFC 8461 section 3.3 forbids them.
  if ! response=$(curl -q --silent --show-error --max-time 20 --max-filesize "$max_policy_bytes" \
    --proto '=https' --tlsv1.2 --output "$body_file" --write-out '%{http_code}\n%{content_type}' \
    "$policy_url" 2>&1); then
    record FAIL "$check" "Fetching ${policy_url} failed: $(clip "$(tail -n 1 <<<"$response")")"
  else
    http_code=$(head -n 1 <<<"$response")
    content_type=$(sed -n 2p <<<"$response")
    if [[ "$http_code" != 200 ]]; then
      record FAIL "$check" "${policy_url} returned HTTP $(clip "$http_code"); it must be 200 without redirects."
    elif [[ ! "${content_type,,}" =~ ^text/plain([[:space:]]*;|$) ]]; then
      record FAIL "$check" "${policy_url} is served as '$(clip "$content_type")'; it must be text/plain."
    else
      fetched=true
      fetch_message="${policy_url} returned HTTP 200 ($(clip "$content_type"))."
    fi
  fi
fi
if [[ "$fetched" == true ]]; then
  # --max-filesize can't stop a server that doesn't send Content-Length, so check the size again.
  size=$(wc -c <"$body_file")
  if ((size > max_policy_bytes)); then
    record FAIL "$check" "The policy is larger than ${max_policy_bytes} bytes; it was not parsed."
  else
    policy_ok=true
    record PASS "$check" "$fetch_message"
  fi
fi

# 5. Certificate lifetime of the policy host
check="Policy host certificate"
if [[ -n "$offline_dir" ]]; then
  :
elif [[ "$policy_ok" != true ]]; then
  record SKIP "$check" "Skipped because the policy could not be fetched."
else
  cert=$(timeout 20 openssl s_client -connect "${policy_host}:443" -servername "$policy_host" </dev/null 2>/dev/null |
    openssl x509 2>/dev/null) || cert=""
  if [[ -z "$cert" ]]; then
    record WARN "$check" "Could not read the certificate of ${policy_host}."
  else
    not_after=$(openssl x509 -noout -enddate <<<"$cert" | cut -d '=' -f 2)
    if ! openssl x509 -noout -checkend 0 <<<"$cert" >/dev/null; then
      record FAIL "$check" "Certificate expired on ${not_after}."
    elif ! openssl x509 -noout -checkend $((min_cert_days * 86400)) <<<"$cert" >/dev/null; then
      record WARN "$check" "Certificate expires on ${not_after}, within ${min_cert_days} days."
    else
      record PASS "$check" "Certificate valid until ${not_after}."
    fi
  fi
fi

# 6. Policy syntax
check="Policy syntax"
mode=""
mx_patterns=()
if [[ "$policy_ok" != true ]]; then
  record SKIP "$check" "Skipped because the policy could not be fetched."
else
  # Tolerate a UTF-8 BOM and CRLF line endings.
  policy=$(sed -e '1s/^\xEF\xBB\xBF//' -e 's/\r$//' "$body_file")
  errors=()
  warnings=()
  declare -A seen=()
  version=""
  max_age=""
  while IFS= read -r line; do
    [[ -z "$(trim "$line")" ]] && continue
    if [[ ! "$line" =~ ^([A-Za-z0-9_-]+)[[:space:]]*:[[:space:]]*(.*)$ ]]; then
      errors+=("invalid line '$(clip "$line")'")
      continue
    fi
    key="${BASH_REMATCH[1]}"
    value=$(trim "${BASH_REMATCH[2]}")
    case "$key" in
      version | mode | max_age)
        if [[ -n "${seen[$key]:-}" ]]; then
          errors+=("duplicate '${key}' field")
        fi
        seen[$key]=1
        printf -v "$key" '%s' "$value"
        ;;
      mx)
        if [[ "$value" =~ ^(\*\.)?[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+\.?$ ]]; then
          mx_patterns+=("$value")
        else
          errors+=("invalid mx '$(clip "$value")'")
        fi
        ;;
    esac
  done <<<"$policy"

  [[ "$version" == STSv1 ]] || errors+=("version must be 'STSv1', got '$(clip "$version")'")
  case "$mode" in
    enforce) ;;
    testing) warnings+=("mode is 'testing', so senders don't enforce the policy yet") ;;
    none) warnings+=("mode is 'none', so the policy is disabled") ;;
    *) errors+=("mode must be enforce, testing or none, got '$(clip "$mode")'") ;;
  esac
  if [[ "$mode" =~ ^(enforce|testing)$ ]] && ((${#mx_patterns[@]} == 0)); then
    errors+=("no mx entries, but mode '${mode}' requires at least one")
  fi
  if [[ ! "$max_age" =~ ^[0-9]{1,10}$ ]]; then
    errors+=("max_age must be a non-negative integer, got '$(clip "$max_age")'")
  elif ((10#$max_age > 31557600)); then
    errors+=("max_age ${max_age} exceeds the maximum of 31557600 seconds (1 year)")
  elif ((10#$max_age < 86400)); then
    warnings+=("max_age ${max_age} is shorter than a day, which gives little protection")
  fi

  summary="version=$(clip "$version"), mode=$(clip "$mode"), max_age=$(clip "$max_age"), mx=$(clip "$(join_by ', ' "${mx_patterns[@]}")")"
  if ((${#errors[@]} > 0)); then
    record FAIL "$check" "$(join_errors "${errors[@]}"). Policy: ${summary}"
  elif ((${#warnings[@]} > 0)); then
    record WARN "$check" "$(join_by '; ' "${warnings[@]}"). Policy: ${summary}"
  else
    record PASS "$check" "$summary"
  fi
fi

# 7. MX records are covered by the policy
check="MX coverage"
if [[ "$policy_ok" != true || -z "$mode" ]]; then
  record SKIP "$check" "Skipped because no valid policy is available."
elif [[ "$mode" == none ]]; then
  record SKIP "$check" "Skipped because the policy mode is 'none'."
elif ! mx_records=$(dns_records "$domain" MX); then
  record FAIL "$check" "DNS lookup of the MX records of ${domain} failed (resolver ${resolver})."
else
  mx_hosts=$(awk '{ print tolower($2) }' <<<"$mx_records" | sed 's/\.$//' | grep . | sort -u || true)
  if [[ -z "$mx_hosts" ]]; then
    record FAIL "$check" "${domain} has no MX records (or a null MX)."
  else
    unmatched=()
    while IFS= read -r mx; do
      matched=false
      for pattern in "${mx_patterns[@]}"; do
        if mx_matches "$mx" "$pattern"; then
          matched=true
          break
        fi
      done
      [[ "$matched" == true ]] || unmatched+=("$mx")
    done <<<"$mx_hosts"
    if ((${#unmatched[@]} == 0)); then
      record PASS "$check" "All MX hosts are covered: $(clip "$(paste -sd ' ' <<<"$mx_hosts")")."
    else
      message="MX host(s) not covered by the policy: $(clip "${unmatched[*]}")."
      if [[ "$mode" == enforce ]]; then
        record FAIL "$check" "${message} Senders will refuse to deliver to them."
      else
        record WARN "$check" "${message} Mail to them would fail once the mode is 'enforce'."
      fi
    fi
  fi
fi

# Summary
result=pass
for r in "${results[@]}"; do
  case "${r%%|*}" in
    FAIL) result=fail ;;
    WARN) [[ "$result" == pass ]] && result=warn ;;
  esac
done

declare -A icons=([PASS]="✅" [WARN]="⚠️" [FAIL]="❌" [SKIP]="⏭️")
report="### MTA-STS check for \`${domain}\`: ${result^^}"$'\n\n'
report+="| | Check | Details |"$'\n'"|---|---|---|"$'\n'
for r in "${results[@]}"; do
  IFS='|' read -r status name message <<<"$r"
  # Messages contain values from DNS and the policy host. A code span keeps them from rendering as mentions, links
  # or HTML in the job summary and in issues. Backticks would end the span, and pipes would end the table cell.
  message="${message//\`/\'}"
  report+="| ${icons[$status]} | ${name} | \`${message//|/\\|}\` |"$'\n'
done

echo
echo "Result: ${result^^}"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  echo "$report" >>"$GITHUB_STEP_SUMMARY"
fi
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  delimiter="EOF_$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
  {
    echo "result=${result}"
    echo "report<<${delimiter}"
    echo "$report"
    echo "$delimiter"
  } >>"$GITHUB_OUTPUT"
fi

if [[ "$result" == fail || ("$result" == warn && "$fail_on_warning" == true) ]]; then
  exit 1
fi
