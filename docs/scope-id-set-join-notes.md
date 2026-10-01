# Why scope id sets are joined, not `IN (subquery)`

When a table is narrowed by a set of ids that another query produces (referenced-by, `reverse_scope`, the narrowed-parent cascade, polymorphic arms, tree ancestors), the SQL adapters emit a `JOIN` to a `SELECT DISTINCT` derived table instead of `<col> IN (<subquery>)`:

```sql
… JOIN (SELECT DISTINCT src.<id> AS exwiw_scope_id FROM (<id-set subquery>) AS src) AS ids
    ON <table>.<col> = ids.exwiw_scope_id
```

Both forms return the same rows; the `DISTINCT` keeps the join from multiplying them. The plans differ on a large table. MySQL cannot turn `IN (… UNION …)` into a materialized semi-join, so it rewrites it into a correlated `EXISTS` that is evaluated once per outer row: a full scan of the outer table, with the union re-run for every row. The `DISTINCT` derived table cannot be merged into the outer query, so it is materialized once and the outer table is probed by its key. On a large `users` table this is the difference between a full scan and an index lookup. Nested cascades are materialized once per level for the same reason.

PostgreSQL casts both sides to `text` when the key types differ (`uuid` against `varchar`).
