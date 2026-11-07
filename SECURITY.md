# Security Policy

## Supported versions

Only the latest commit on [`main`](https://github.com/iimgaurav/dbt_e-com_project/tree/main)
is supported. Fixes are delivered as pull requests against `main` and promoted to
production by the `dbt Deploy` workflow.

## Reporting a vulnerability

Please do **not** open a public issue for security problems.

- Use **Security → Report a vulnerability** (private vulnerability reporting) to
  report privately to the maintainer, **or**
- Contact the maintainer directly on GitHub: [@iimgaurav](https://github.com/iimgaurav).

We aim to acknowledge reports within 72 hours and to ship a fix or mitigation
within 14 days for issues with real impact.

## What this repository contains

| Area | Sensitivity |
|---|---|
| dbt project (`models/`, `macros/`, `seeds/`) | Low — transforms data, contains no credentials |
| GitHub Actions workflows (`.github/`) | **High** — receive the `DATABRICKS_*` secrets; every change goes through a PR gated by the `dbt CI` check |
| Scheduler (`scheduler/`) | Medium — runs dbt as a subprocess; holds no tokens itself |
| Secrets | Never committed. See [docs/SECURITY.md](docs/SECURITY.md) for the full secrets model and token-handling policy |

## Automated security features enabled

- **Secret scanning + push protection** — credential leaks are blocked at push time
- **Dependabot alerts and security updates** — dependency advisories open PRs
  (see [.github/dependabot.yml](.github/dependabot.yml))
- **CodeQL code scanning** for `python` and `actions`
  ([.github/workflows/codeql.yml](.github/workflows/codeql.yml))
- **Branch ruleset on `main`** — pull requests only, `dev build (PR)` must be green,
  no force-pushes or deletions
- **Deployment gating** — only `main` may deploy to the `production` environment
