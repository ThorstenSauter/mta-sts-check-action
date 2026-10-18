# MTA-STS check

A GitHub Action that validates the [MTA-STS (RFC 8461)](https://www.rfc-editor.org/rfc/rfc8461) and
[TLS-RPT (RFC 8460)](https://www.rfc-editor.org/rfc/rfc8460) configuration of a mail domain from the outside, the way a
sending mail server sees it. It doesn't matter how the policy is hosted or deployed.

Run it on a schedule so you notice when a record has been changed by hand, the policy host's certificate is about to
expire, or the domain's MX hosts no longer match the policy. In `enforce` mode, that last case makes senders refuse to
deliver mail.

## Checks

| Check | Fails when | Warns when |
|---|---|---|
| `_mta-sts.<domain>` TXT | there is not exactly one `v=STSv1` record, or its `id` is not 1–32 alphanumeric characters | |
| `_smtp._tls.<domain>` TXT | there are several `v=TLSRPTv1` records, `rua` is missing, or a `rua` URI is not `mailto:`/`https:` | there is no TLS-RPT record |
| Policy host DNS | `mta-sts.<domain>` has no A/AAAA record | |
| Policy file | `https://mta-sts.<domain>/.well-known/mta-sts.txt` doesn't return HTTP 200 without redirects, the certificate is invalid, or the content type is not `text/plain` | |
| Policy host certificate | the certificate has expired | the certificate expires within `min-cert-days` |
| Policy syntax | `version` is not `STSv1`, `mode` is invalid, there are no `mx` entries in `enforce`/`testing` mode, `max_age` is invalid or longer than one year, or a field is duplicated | `mode` is `testing` or `none`, or `max_age` is shorter than a day |
| MX coverage | an MX host matches no `mx` pattern in `enforce` mode, or the domain has no MX records | an MX host matches no `mx` pattern in `testing` mode |

The results are written to the job summary and to the `report` output as a Markdown table.

All DNS lookups go over TCP to the configured resolver. Responses aren't DNSSEC-validated, so treat the result as
monitoring, not as proof.

## Inputs

| Name | Description | Default |
|---|---|---|
| `domain` | The mail domain to check, e.g. `example.com`. | (required) |
| `resolver` | The DNS server that all lookups are sent to. | `1.1.1.1` (Cloudflare) |
| `min-cert-days` | Warn when the policy host's certificate expires within this many days. | `14` |
| `fail-on-warning` | Fail the step on warnings as well as on errors. | `false` |

## Outputs

| Name | Description |
|---|---|
| `result` | `pass`, `warn` or `fail` |
| `report` | The results of all checks as a Markdown table. |

The action runs on Linux runners. It uses `dig`, `curl` and `openssl`. If `dig` is missing, it installs
`bind9-dnsutils` with `sudo apt-get`. On a self-hosted runner, that changes the machine, so install `dig` beforehand
if you don't want that.

## Security

The action reads data that whoever controls the checked domain's DNS or policy host can choose. It treats that data as
untrusted:

- `domain` must be a valid hostname, and `resolver` must be an IP address or a hostname. Anything else stops the action
  before it makes any network request.
- Policy files larger than 64 KiB are refused.
- Values from DNS and the policy are shortened in messages, and at most five policy errors are listed. In the job
  summary and the `report` output they appear in code spans, so they can't render as mentions, links or HTML when you
  post the report to an issue.
- `dig` and `curl` ignore `~/.digrc` and `~/.curlrc`. Redirects aren't followed, and only HTTPS with TLS 1.2 or newer
  is accepted.

Pass the `report` output to scripts through `env:`, as in the example below, never by interpolating
`${{ steps.check.outputs.report }}` into a `run:` script.

Report vulnerabilities privately through the repository's Security tab (see the [security policy](https://github.com/ThorstenSauter/mta-sts-check-action/security/policy)).

## Example: weekly check with a tracking issue

The workflow below runs every Monday. When the check fails, it opens an issue (or comments on the open one). When the
check passes again, it closes the issue. It doesn't need any secrets.

```yaml
name: Weekly MTA-STS check

on:
  schedule:
    - cron: '0 6 * * 1' # Mondays 06:00 UTC
  workflow_dispatch:

permissions: {}

jobs:
  check:
    name: Validate MTA-STS configuration
    runs-on: ubuntu-latest
    permissions:
      issues: write # Opens, comments on and closes the tracking issue
    timeout-minutes: 10
    env:
      MTA_STS_DOMAIN: example.com
    steps:
      - name: Validate MTA-STS configuration
        id: check
        uses: ThorstenSauter/mta-sts-check-action@f3cb719e3193f2c68ba5c902c538996e86d6d1f4 # v1.0.0
        with:
          domain: ${{ env.MTA_STS_DOMAIN }}
      - name: Open, update or close the tracking issue
        if: always()
        uses: actions/github-script@3a2844b7e9c422d3c10d287c895573f7108da1b3 # v9.0.0
        env:
          OUTCOME: ${{ steps.check.outcome }}
          REPORT: ${{ steps.check.outputs.report }}
        with:
          script: |
            const label = 'mta-sts-check';
            const runUrl = `${context.serverUrl}/${context.repo.owner}/${context.repo.repo}/actions/runs/${context.runId}`;
            const { data: issues } = await github.rest.issues.listForRepo({
              ...context.repo,
              state: 'open',
              labels: label,
            });
            const issue = issues[0];

            if (process.env.OUTCOME !== 'success') {
              const body = `${process.env.REPORT || 'The check did not produce a report.'}\n\n[Workflow run](${runUrl})`;
              if (issue) {
                await github.rest.issues.createComment({ ...context.repo, issue_number: issue.number, body });
              } else {
                await github.rest.issues.create({
                  ...context.repo,
                  title: `MTA-STS check failed for ${process.env.MTA_STS_DOMAIN}`,
                  labels: [label],
                  body,
                });
              }
            } else if (issue) {
              await github.rest.issues.createComment({
                ...context.repo,
                issue_number: issue.number,
                body: `The MTA-STS check passes again. [Workflow run](${runUrl})`,
              });
              await github.rest.issues.update({
                ...context.repo,
                issue_number: issue.number,
                state: 'closed',
                state_reason: 'completed',
              });
            }
```

Pin actions to a full commit SHA as shown, with the version as a comment, so tools like Renovate can update them.
The moving `v1` tag always points at the latest `v1.x.y` release.

GitHub disables scheduled workflows in repositories that have had no activity for 60 days. Regular dependency
updates, for example from Renovate, keep the repository active.

## Running locally

```sh
./check.sh example.com
RESOLVER=8.8.8.8 MIN_CERT_DAYS=30 ./check.sh example.com
```

## Development

```sh
shellcheck check.sh tests/run.sh
bash tests/run.sh
```

`tests/run.sh` runs `check.sh` in offline mode against each directory in `tests/fixtures/`. A fixture has a `dns.txt`
with DNS answers in `dig` answer format, a `policy.txt`, and an `expected` file with the expected result (`pass`,
`warn`, `fail`, or `error` for input that must be rejected). Optional files: `domain` and `resolver` override the
inputs, and `expected-output` lists lines that must appear in the console output or the report. In offline mode the
certificate check is skipped. The action itself always turns offline mode off.
