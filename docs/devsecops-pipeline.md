# DevSecOps CI/CD Pipeline

This document describes the security scanning pipeline and multi-stage deployment workflow added to the [secure static website](../README.md) project.

---

## What Changed From the Basic Pipeline

Initially, this project shipped with a simple four-job pipeline: lint → deploy-infra → deploy-website → smoke test. That pipeline was functional but had no security gates, no pre-production validation environment, and no manual approval before production changes went live.

Now, it is updated:

![CI/CD Pipeline Detailed](./assets/cicd-detailed-diagram.svg)

---

## The Two Workflows

### `pr-checks.yml` — runs on every PR targeting `main`

Triggered whenever `infrastructure/**` or `.github/workflows/**` files change in a pull request. Three jobs run in parallel; a fourth collects their results and posts a structured comment on the PR:

The **cfn-lint** job checks CloudFormation syntax, property types, resource constraints, and AWS best-practice warnings (`-W` flag includes warnings, not just errors). It's fast (~15 seconds) and catches the most common template mistakes before anything heavier runs.

The **cfn-nag** job runs CloudFormation-specific security analysis — things cfn-lint doesn't cover, like IAM wildcard policies, missing encryption, security groups open to `0.0.0.0/0`, and S3 buckets without logging. Findings come in two severities: `WARN` (advisory) and `FAIL` (blocks the pipeline). The job only fails on `FAIL`-level findings.

The **checkov** job applies over a thousand cross-resource security policies. It also produces a SARIF report that uploads to the repository's Security tab, where findings appear inline on the changed files in the PR. This is the most comprehensive of the three scanners and is the one most likely to catch novel misconfigurations.

### `deploy.yml` — runs on push to `main`

Seven sequential stages. The key additions over the original pipeline:

**Security scan gate** — cfn-nag and checkov run again on every push to main, not just PRs. This matters because someone could push directly to main bypassing the PR workflow. The gate ensures no deployment proceeds with known security failures regardless of how the code reached main.

**Staging environment** — a second CloudFormation stack (`secure-static-site-staging`) is deployed before production. It uses the same template with `Environment=staging` and a lower WAF rate limit (500 req/5min vs 2000). If the template has a deployment error that cfn-lint and cfn-nag didn't catch, it surfaces here against real AWS APIs before touching production.

**Manual approval gate** — the `approve-production` job maps to a GitHub Environment named `production` which has Required Reviewers configured. The pipeline pauses at this stage and sends a notification to the configured reviewers. No code reaches production without a human sign-off. This is the same pattern used in enterprise CI/CD systems.

---

## cfn-nag Suppressions

cfn-nag suppressions live directly in `infrastructure/template.yaml` as `Metadata.cfn_nag` blocks on each resource. This keeps the justification co-located with the resource rather than in a separate file that can drift out of sync.

| Resource | Rule | Justification |
|---|---|---|
| `LogsBucket` | `W35` (no access logging) | This bucket IS the log destination — logging to itself is circular and unsupported by AWS |
| `AthenaResultsBucket` | `W35` (no access logging) | Short-lived query results; activity auditable via CloudTrail |
| `AthenaResultsBucket` | `W41` (no versioning) | Ephemeral outputs; versioning would retain every result set indefinitely |
| `WebACL` | `W68` (no WAF logging) | WAF logging requires Firehose (~$15-20/month); CloudFront logs cover this use case |
| `CloudFrontDistribution` | `W70` (default TLS cert) | Default cert used in no-domain config; TLSv1.2_2021 enforced when custom domain enabled |

The suppressions are **not** a way to make the scanner go quiet — each one documents a deliberate architectural decision.

### What cfn-nag would catch without suppressions — an example

The `W35` rule on `LogsBucket` is a good example of the scanner doing its job correctly. The rule says: "S3 bucket should have access logging enabled." Without the suppression, cfn-nag flags it as a warning. The *reason* it doesn't apply here is architectural — you can't log to the logging bucket — and the suppression documents exactly that. A reviewer reading the template can immediately understand why the warning was accepted.

---

## Checkov Skips

Checkov skips are in `.checkov.yaml` at the repository root. The same principle applies: each skip has a `reason` field that must explain the *why*.

| Check | Reason |
|---|---|
| `CKV_AWS_18` | Access logging (same reasoning as W35 above) |
| `CKV_AWS_21` | S3 versioning on Athena results bucket |
| `CKV2_AWS_31` | WAF logging (same reasoning as W68 above) |
| `CKV_AWS_305` | Default CloudFront cert in no-domain config |
| `CKV_AWS_310` | Origin failover not needed — S3's built-in durability is sufficient |

---

## GitHub Environment Setup

The manual approval gate requires a one-time manual setup in GitHub. The pipeline code handles everything else automatically.

Go to **Repo → Settings → Environments → New environment** and create two environments:

**`staging`** — no protection rules. Deployments here happen automatically after the security scan passes.

**`production`** — add yourself (and any co-reviewers) under Required reviewers. Optionally set a deployment branch rule to `main` only. When the pipeline reaches the `approve-production` job, GitHub sends an email notification to the required reviewers and pauses the run until one of them approves via the Actions UI.

---

## SARIF and the Security Tab

Every run of the checkov scanner uploads a SARIF (Static Analysis Results Interchange Format) file to GitHub's code scanning API. This populates the **Security → Code scanning** tab of the repository with structured findings — tool name, severity, file location, line number, and remediation guidance.

SARIF integration means:
- Findings from checkov appear inline on the PR diff, next to the relevant line of the template
- The Security tab shows a historical trend of findings across commits
- GitHub can automatically dismiss findings that have been suppressed in `.checkov.yaml`

This is the same integration used by tools like CodeQL, Snyk, and Semgrep in enterprise security workflows.

---

## Cost Impact

The DevSecOps additions are entirely free to run:

- GitHub Actions minutes: ~4-6 minutes per PR check run, ~12-15 minutes per full deploy pipeline
- cfn-lint, cfn-nag, checkov: open-source, no licensing cost
- SARIF upload: included in GitHub's code scanning feature (available on public repos and GitHub Team/Enterprise)
- Staging stack: adds a second CloudFront distribution + WAF Web ACL → approximately doubles the infrastructure cost while the staging stack is running (~$7-8/month extra). Tear down with `make destroy STACK_NAME=secure-static-site-staging`.
