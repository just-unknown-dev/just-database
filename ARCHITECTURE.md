# just_database architecture

This describes how just_database 2.x works inside, for people changing it.
For using it, read the [README](README.md).

## Layers

`lib/src` is split by feature. A feature only imports features in its own
layer or below (checked by `test/library_layout_test.dart`):

| Layer | Features | What they hold |
|---|---|---|
| 0 | `sql` | lexer, parser, syntax tree, `SqlException` |
| 0 | `storage` | values and affinity, schemas, tables, indexes, the R-tree, the catalog, the undo log |
| 1 | `engine` | the SQL engine: compiles and runs statements against a catalog |
| 1 | `persistence` | the file codec (formats 1 and 2), the encryption envelope, the SQL dump, the store interface |
| 2 | `io`, `web` | the platform stores: files with `dart:io`, IndexedDB and WebCrypto with `package:web` |
| 3 | `core` | `JustDatabase`, `DatabaseManager`, migrations, the query builder, `SecureKeyManager` |
| 4 | `orm`, `benchmark` | `DbTable`, benchmarks |
| 5 | `ui` | the admin UI (only exported by `ui.dart`) |

`lib/just_database.dart` exports the public API of layers 0–4;
`lib/ui.dart` exports the UI.

## A statement's life

1. `JustDatabase.execute(sql, params)` takes the database's async lock
   (`AsyncLock`, first come first served). Inside `transaction()` the zone
   marks the caller as the lock's holder, so its statements run at once.
2. `Parser.parseOne` tokenizes (`lexer.dart`) and parses (`parser.dart`) the
   text into a `Statement`, numbering its parameters. Anything after the
   statement but a `;` is an error.
3. Parameters are bound to a positional list (`bindValue` turns `bool`,
   `DateTime` and `List<int>` into SQL values).
4. `Engine.execute` runs the statement synchronously:
   * It takes an undo-log *hold* and a *mark*.
   * The statement is compiled: every expression becomes a closure
     (`_Eval = Object? Function(_Frame)`) with its column references
     resolved to (scope depth, source, column) at compile time.
   * It runs. Every change to a table or the catalog records how to undo
     itself in the `UndoLog`.
   * On any error the log is rolled back to the mark, so the statement
     changed nothing (`OR FAIL` keeps what it did; `OR ROLLBACK` and
     `RAISE(ROLLBACK)` also end the transaction).
   * Deferred foreign key checks (`NO ACTION`) run before it returns.
5. `JustDatabase` wraps the outcome in a `QueryResult` and, if something
   changed and no transaction is open, starts a save.

Because a statement runs without yielding, no other statement ever sees it
half done.

## Values

Values are SQLite's storage classes: `null`, `int`, `double`, `String`,
`Uint8List` (`storage/values.dart`). Column affinity (`Affinity.of`) decides
what a stored value becomes (`applyAffinity`); comparisons apply SQLite's
rules (`_comparisonConverters`): numeric affinity converts the other side,
text affinity converts an untyped side. `compareValues` orders NULL <
numbers < text < blobs, text by collation (`BINARY`, `NOCASE`, `RTRIM`).
`keyOf` maps values SQL treats as equal (`1` and `1.0`; strings equal
under a collation) to one hashable key, used by `GROUP BY`, `DISTINCT`,
joins and indexes.

## Storage

* `TableData` keeps rows in a `SplayTreeMap<int, List<Object?>>` by rowid, a
  list per row in column order. Row lists are never changed in place;
  updates replace them.
* `TableIndex` is a hash index from a key to one rowid or a set of rowids.
  Rows with a NULL in the key are not indexed (NULL never matches and never
  conflicts). Constraint indexes are named `sqlite_autoindex_<table>_<n>`;
  internal `sqlite_fkindex_…` indexes on foreign key columns make cascades
  fast and are never listed or saved.
* `SpatialIndex` wraps an `RTree` (Guttman, quadratic split) over two
  numeric columns.
* `Catalog` holds tables, views and triggers (views and triggers as their
  SQL text) and bumps `schemaVersion` on every schema change, which drops
  the engine's compiled views and triggers.
* `UndoLog` records undo closures while a statement or transaction holds
  it. `rollbackTo(mark)` undoes newer entries. A transaction holds it from
  `BEGIN` to `COMMIT`; savepoints are marks. `mutations` counts changes (and
  un-counts undone ones), which tells `JustDatabase` whether anything needs
  saving.

## The engine

`engine/engine.dart` is one library split into parts:

* `scope.dart`: sources (a table, view, subquery, or a trigger's NEW/OLD),
  scopes (the sources a query sees, with its parent for correlated
  subqueries) and frames (the current row of each source at run time).
  Name resolution raises "ambiguous column name" and "no such column".
* `compiler.dart`: expressions to closures, with three-valued logic,
  overflow-checked integer arithmetic, `LIKE`/`GLOB`, `IN` (hashed when its
  list is constant), subqueries (results cached per execution unless
  correlated), `CASE`, `CAST`, and aggregate calls, which become reads of
  the group's results.
* `select.dart`: flattens `FROM` into levels and runs nested loops. A join
  level with equality keys hashes its rows once per run (or uses a table
  index); the first level uses a rowid, index or spatial lookup when `WHERE`
  allows; `WHERE` conjuncts are checked at the earliest level that has
  their columns (at the end when a `RIGHT`/`FULL` join is present). Then
  grouping, `HAVING`, `DISTINCT` (hashed), `ORDER BY` (keys computed from
  the source rows, so a sort column need not be selected), `LIMIT`. Compound
  selects combine the rows of their cores.
* `dml.dart`: `INSERT`/`UPDATE`/`DELETE`, conflict handling and upserts,
  `CHECK`/`NOT NULL`/`UNIQUE` (after affinity), triggers (no recursion, depth
  limit 1000, `RAISE`), foreign keys (child checks, parent actions,
  `NO ACTION` deferred to the statement's end) and `INSTEAD OF` triggers
  on views.
* `ddl.dart`: `CREATE`/`DROP`/`ALTER` with SQLite's rules; `rename.dart`
  rewrites stored view, trigger and `CHECK` text token by token when a table
  or column is renamed.
* `functions.dart`, `datetime.dart`, `geometry.dart`, `aggregates.dart`: the
  built-in functions.

## Persistence

* `JustDatabase` saves the whole catalog after each committed change. The
  snapshot is encoded under the lock, between statements and never during
  a transaction; encryption and the write happen outside the lock. Saves
  that pile up merge into one (`_startSave`); `writeFast` delays them.
* `persistence/codec.dart` encodes format 2 and decodes formats 1 and 2.
* The platform store (`io/file_store.dart`, `web/idb_store.dart`) reads,
  writes atomically (temp file, flush, rename; retried briefly on Windows),
  lists and deletes, takes a lock per database (an OS file lock; Web
  Locks), and provides PBKDF2 and AES-GCM (background isolates; WebCrypto).

### Format 2 (plain)

UTF-8 JSON:

```json
{"format": "just_database", "version": 2, "userVersion": 0,
 "tables": [{"schema": {"name": "t", "columns": [{"name": "id", "type": "INTEGER", "primaryKey": true}],
             "constraints": []},
             "sequence": 0,
             "rows": [[1, …], …],
             "indexes": [{"name": "ix", "columns": ["a"], "unique": false}],
             "spatial": [{"name": "sx", "x": "lng", "y": "lat"}]}],
 "views": [{"name": "v", "sql": "CREATE VIEW …"}],
 "triggers": [{"name": "tr", "table": "t", "sql": "CREATE TRIGGER …"}]}
```

Each row starts with its rowid. A blob is `{"$blob": "<base64>"}`; an
infinite real is `{"$real": "Infinity"}` or `"-Infinity"`. A reader refuses
a `version` it does not know.

### Format 2 (encrypted)

```
"JDB" 0x02 | kdf 0x01 (PBKDF2-HMAC-SHA256) | iterations (uint32, big-endian)
| salt length (1 byte) | salt | nonce (12) | AES-256-GCM(ciphertext + 16-byte tag)
```

The whole header is the GCM additional data.

### Format 1 (1.x)

Plain files are JSON with `"version": 1` and tables keyed by name; columns
carry a `DataType`, rows are arrays without rowids, values use
`{"__type": "blob" | "datetime", "data": …}`. Encrypted files are
`IV (12) | ciphertext | tag` with the key `SHA-256(passphrase)`.
`_decodeV1` converts them: types become declared types, booleans `1`/`0`,
dates ISO text, an `INTEGER PRIMARY KEY` the rowid; keys the data breaks are
dropped with a warning.

## Concurrency

All statements of a database run on one engine, one at a time. The async
lock orders callers; `transaction()` holds it for its whole callback. Saves
take it only to encode. `readFast` lets a `SELECT` skip the queue when no
transaction is open. A process-wide registry returns the open instance for
a name (reference-counted `close`), and the store's lock keeps other
processes and tabs out. Isolates of one process are not kept apart on
POSIX systems (file locks there belong to the process).

## Known trade-offs

* Whole-database saves: simple and atomic, but their cost grows with the
  database.
* Hash indexes only: no range scans, no index-ordered `ORDER BY`.
* Renames rewrite stored SQL by tokens; a name reused for something else in
  a trigger can be renamed with it.
* Integers are 64-bit on native platforms and 53-bit on the web.
