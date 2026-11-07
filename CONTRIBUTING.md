# Contributing

Thanks for improving this project. This is a production-style dbt repository:
every change goes through a pull request with a green CI build.

## Ground rules

1. **Never commit secrets.** Tokens come from environment variables / GitHub
   secrets only (see [docs/SECURITY.md](docs/SECURITY.md)).
2. **Every PR must pass `dbt CI`** — it builds the whole project into the dev
   catalog and enforces the quality gate (warnings ≤ baseline, zero errors).
3. **Conventional commits** — `fix:`, `feat:`, `docs:`, `ci:`, `chore:` … the
   history is read by humans and tools alike.

## Development workflow

```bash
git clone https://github.com/iimgaurav/dbt_e-com_project.git
cd dbt_e-com_project
dbt deps --profiles-dir .                  # parity with CI (no-op: no packages)
dbt build --profiles-dir . --target dev    # baseline: 102 total | 97 success | 5 warn | 0 error
```

- `main` is protected: **pull requests only**, and the `dev build (PR)` check
  must be green before merging.
- Merging to `main` deploys to production automatically (`dbt Deploy`, gated by
  the `production` environment which only accepts `main`).

## dbt conventions

| Layer | Naming | Notes |
|---|---|---|
| bronze | `stg_*` | staging views, raw-as-string columns |
| silver | `slv_*` | typed, canonical, deduped tables |
| gold | `dim_*`, `fct_*` | star schema for BI |
| observability | `pipeline_step_*`, `idempotency_check` | views, tag `observability` |

- Every model gets a `description` and column-level tests in its `schema.yml`.
- Prefer tests over doc-only claims: a new invariant means a new test.
- Logging goes through the macros in `macros/logging.sql` and
  `macros/observability.sql` — no ad-hoc `log()` calls.
- New test warnings must be justified in `docs/DATA_QUALITY.md`, and the
  `EXPECTED_WARNINGS` baseline raised **in the same PR** in both workflows.

## Pull request checklist

- [ ] `dbt build --target dev` matches the documented baseline, or the baseline
      is consciously updated in `dbt_ci.yml` **and** `dbt_deploy.yml`
- [ ] New/changed models are documented in `schema.yml` and `docs/`
- [ ] No secrets, tokens or hostnames in the diff
- [ ] Conventional commit message

## Reporting bugs and security issues

Use the issue templates for bugs and features. Security issues go through the
private channel in [SECURITY.md](SECURITY.md) — never a public issue.
