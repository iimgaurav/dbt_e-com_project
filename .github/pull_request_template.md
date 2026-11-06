## What does this PR change?

<!-- One or two sentences. Reference the ticket if there is one. -->

## Type

- [ ] New model / model change
- [ ] Test or data-quality rule
- [ ] Macro, snapshot or incremental-strategy change
- [ ] CI/CD, docs or tooling

## Checklist

- [ ] `dbt build --profiles-dir . --target dev` is green locally (0 errors).
- [ ] Warning count is at or below the baseline (see [docs/CI_CD.md](docs/CI_CD.md#7-quality-gate)).
- [ ] CI check **`dev build (PR)`** passed on this PR.
- [ ] New/changed columns have `not_null`, `unique` or `relationships` tests.
- [ ] Uses `ref()` / `source()` only - no hard-coded schema or catalog names.
- [ ] No secrets, tokens, warehouse IDs or credentials in the diff.
- [ ] Docs updated (`schema.yml` descriptions, and [docs/DATA_DICTIONARY.md](docs/DATA_DICTIONARY.md) for new tables).
- [ ] I have called out any breaking change: `unique_key`, grain,
      `incremental_strategy`, snapshot strategy, or anything needing
      `--full-refresh` in prod.

## Breaking change?

<!-- If yes: describe the backfill / full-refresh plan and get a second approval. -->
