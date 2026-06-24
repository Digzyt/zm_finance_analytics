# Disciplines for the PostgreSQL → Fabric Switch

> Five rules that have to be respected today so the Fabric switch is a profile change and a CI pass — not a rewrite. Read this before adding any SQL to the project.

## Why these matter

dbt is designed to be database-agnostic at the project level, but only if the SQL inside models is dialect-portable. PostgreSQL and Microsoft Fabric Warehouse (T-SQL on the Polaris engine) have substantially different syntax for date functions, string operations, JSON handling, identifier casing, and incremental materialization. If we use Postgres-specific syntax now, we'll rewrite models when Fabric arrives — which is exactly what dbt is meant to prevent.

The five disciplines below are the practical operational rules that keep portability cheap.

---

## Discipline 1 — Define sources from day one, not seeds in `ref()`

**Rule:** Models read from `{{ source('bronze_source', 'gl_entry_zaac') }}`, never `{{ ref('gl_entry_zaac') }}`, even though the data today comes from seeds.

**Why:** When Fabric arrives, the sources YAML stays where it is — only the underlying schema location changes (from seeded Postgres tables to real Fabric raw tables). Source declarations are stable; seed files come and go. If we use `ref()` to read seeded data today, every staging model has to be rewritten to use `source()` at switch time.

**How to do it:**

Seeds are loaded into the `bronze_source` schema (configured in `dbt_project.yml`). Sources are declared in `models/staging/_sources.yml` against that same schema. Models then `source()` against them. The seed → table → source chain is invisible to model code.

At switch time, the sources YAML is edited to either:
- Point to a different database/schema where Fabric raw tables live, or
- Use a Jinja conditional `{% if target.type == 'fabric' %}` to switch source coordinates per environment.

---

## Discipline 2 — No PostgreSQL-specific SQL in models

**Rule:** If a function exists only in PostgreSQL, don't use it directly. Use a dbt cross-database macro, a `dbt-utils` helper, or — if no portable option exists — a custom `adapter.dispatch` macro.

**What's safe (works on both adapters):**

- ANSI SQL: SELECT, FROM, WHERE, JOIN, CTE (`WITH`), window functions, CASE, COALESCE, NULLIF.
- Numeric: arithmetic, ROUND, ABS, FLOOR, CEIL.
- String basics: UPPER, LOWER, TRIM, LENGTH.
- Date basics: column references, IS NULL, simple comparisons.

**What breaks across adapters — use the alternatives:**

| Postgres-only | Use this instead |
|---|---|
| `\|\|` (string concat) | `{{ dbt.concat([...]) }}` |
| `TO_CHAR(d, 'YYYY-MM')` | `{{ dbt.date_trunc('month', 'd') }}` for month start, or `to_char` wrapped in dispatch |
| `DATE_TRUNC('month', d)` | `{{ dbt.date_trunc('month', 'd') }}` |
| `EXTRACT(MONTH FROM d)` | `{{ dbt.date_part('month', 'd') }}` |
| `LIMIT n` | `{{ dbt.limit_zero() }}` for zero-row predicates; otherwise platform-neutral CTE tricks |
| `JSONB ->>`, `@>`, `?` | Wrap in `adapter.dispatch` macro; T-SQL uses `JSON_VALUE`, `JSON_QUERY`, `OPENJSON` |
| `ILIKE 'x%'` | `LOWER(col) LIKE LOWER('x%')` |
| `GENERATE_SERIES(...)` | `dbt_utils.date_spine(...)` for date ranges; recursive CTE for integer ranges |
| `CAST(x AS TEXT)` | `{{ dbt.type_string() }}` for column type definitions |
| `NUMERIC(20,4)` in models | `{{ dbt.type_numeric() }}` |

**Cross-database macros to reach for first:**

- `dbt.date_trunc(period, column)`
- `dbt.dateadd(period, n, column)`
- `dbt.datediff(start, end, period)`
- `dbt.date_part(part, column)`
- `dbt.concat([col_a, col_b, ...])`
- `dbt.type_string()`, `dbt.type_numeric()`, `dbt.type_timestamp()`, `dbt.type_int()`, `dbt.type_bigint()`
- `dbt_utils.date_spine(...)` (in dbt-utils package)
- `dbt_utils.surrogate_key(...)` (in dbt-utils)

**For genuinely necessary dialect splits:** put the logic in `macros/cross_db_helpers.sql` using `adapter.dispatch`, with a Postgres version and a Fabric version side-by-side. Example skeleton is in that file.

---

## Discipline 3 — Push warehouse-specific quirks into the staging layer

**Rule:** Source-system quirks (Postgres `JSONB` for the `Original_Row_JSON` column, T-SQL `JSON` strings on the Fabric side) are absorbed in staging. Intermediate and mart models never see them.

**Why:** Marts get reused. If a mart depends on Postgres-specific syntax even via a deep join chain, the rewrite at Fabric-switch is expensive. If the dialect difference is bounded to staging, the blast radius is bounded too.

**How to do it:**

- Staging models do one job: select from source, rename to internal conventions, cast types using dbt cross-DB type macros, and apply any source-specific quirks (JSON extraction, encoding fixes).
- Anything that touches a Postgres-specific function lives in a staging model. Never in intermediate or marts.

---

## Discipline 4 — Target Fabric Warehouse (not Lakehouse) for dbt materializations

**Rule:** dbt-fabric writes to Fabric **Warehouse**, not Lakehouse. Sources can be either. Decide on warehouse-as-target up front and architect for it.

**Why:** Fabric has two SQL surfaces. The Lakehouse SQL endpoint is **read-only** — dbt can `source()` from it but cannot materialize tables into it. The Warehouse is fully writable T-SQL and is what `dbt-fabric` targets. The common shape for BC-based projects is:

- BC raw extracts land in the Lakehouse (Delta tables in OneLake).
- dbt sources reference the Lakehouse SQL endpoint (`bronze` schema).
- dbt models materialize into the Warehouse (`silver`, `gold` schemas).

**Practical implication today:** when we configure the Fabric target, make sure the engineer provisions a Warehouse (not just a Lakehouse) and has WRITE permission on it via the service principal that dbt will authenticate as.

---

## Discipline 5 — Parity tests against both adapters from day one of Fabric availability

**Rule:** The same dbt project must `dbt build` cleanly against both PostgreSQL and Fabric on every CI run, starting the day Fabric access is provisioned.

**Why:** Dialect drift is silent. A SQL statement that runs fine on Postgres might fail at parse time on Fabric, or worse, run but return slightly different values (date arithmetic edge cases, NULL semantics in aggregations, ORDER BY with NULLS LAST). Catching this on day one when there are two models in the project is cheap; catching it in week eight with eighty models is expensive.

**How to do it:**

- A small fixed sample of seed data (a few hundred rows per entity, deterministic) that's loadable into both Postgres and Fabric.
- CI runs `dbt build --target dev_pg` and `dbt build --target prod_fabric` in parallel.
- A custom test (in `tests/`) asserts that key mart values are identical between the two builds for the sample data.
- Build fails if either adapter errors or if parity test fails.

---

## Things that will still bite even with the disciplines

These are the realistic gotchas, not theoretical ones. Budget time for them at switch time.

1. **Incremental materialization strategies differ.** Postgres uses `delete+insert` by default; `dbt-fabric` supports `merge` and `append`. If you use incremental models, test the strategy on Fabric early.
2. **Materialized views are a Postgres feature.** Fabric Warehouse doesn't have them in the same form. dbt's `materialized_view` materialization is adapter-specific. We avoid materialized views in this project for portability — use `table` instead.
3. **Performance characteristics are completely different.** A query plan that's fast on a small Postgres prototype can be slow on Fabric Warehouse with real data volumes (columnar storage, MPP fan-out), or vice versa. Don't extrapolate timings.
4. **Auth model.** Service principal / Entra ID auth is a different setup pattern from Postgres user/password. Allow time for it.
5. **Schema / database boundary.** PostgreSQL `database.schema.table`; Fabric `database.schema.table` but databases are warehouse-scoped. The source declarations may need a `{% if target.type == 'fabric' %}` block for the database name.
6. **Identifier quoting.** This project uses double-quoted PascalCase column names (`"Posting_Date"`) to preserve BC naming verbatim. PostgreSQL respects this case when quoted. Fabric T-SQL is case-insensitive but case-preserving — quoted identifiers work but unquoted ones also match. The double-quoted style is safe on both.

---

## Sign-off checklist before declaring "ready to switch"

Use this checklist when BC access lands and you're preparing to flip the target:

- [ ] `dbt-fabric` adapter installed and `profiles.yml` updated with the `prod_fabric` target
- [ ] Service principal provisioned in Entra ID with WRITE access to the target Fabric Warehouse
- [ ] All Postgres-only SQL audited — every model passes `grep`-based dialect linting (see `macros/cross_db_helpers.sql` for the linter regex)
- [ ] Bronze sources in `_sources.yml` updated to point at Fabric Lakehouse raw tables
- [ ] CI passes against both `dev_pg` and `prod_fabric` targets
- [ ] Parity test (`tests/assert_parity_pg_vs_fabric.sql`) passes for the fixed sample dataset
- [ ] At least one full production-volume `dbt build` against Fabric completed and benchmarked
- [ ] Power BI semantic model connection re-pointed at Fabric Warehouse (this is a Power BI–side change, not dbt)
