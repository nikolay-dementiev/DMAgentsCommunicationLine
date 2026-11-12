# Database schema

The schema is new and open until the first release: it may change without a compatibility path.
The schema version is kept in `PRAGMA user_version`. Migrations are numbered `1, 2, 3, ...` without gaps and
live in `SchemaMigrations`. Each string of a migration holds exactly one statement; a string with more is
rejected with `StoreError.multipleStatements` instead of silently running only the first. Each migration runs in one transaction together with the update of the version,
so a failed migration leaves both the schema and the version as they were. A database whose version is newer
than the code fails to open with `StoreError.newerSchema` and is not modified.

## Connection

- Write-ahead logging (`journal_mode = WAL`); opening fails if the file system does not accept it.
- Foreign keys are switched on for the connection. Schema version 1 declares none.
- Opening is safe when several processes start at once: the schema version is read again inside each
  migration transaction, an existing folder or file is checked instead of failing, and the switch to
  write-ahead logging is retried while another process holds the file, up to the busy timeout.
- The busy timeout (milliseconds) is a parameter of `SQLiteStore.open`; the composition root reads it from
  the setting `store.busy_timeout`.

## File permissions

- The store folder is created with mode `0700` and the database file with mode `0600`, whatever the process
  umask. SQLite creates the `-wal` and `-shm` files with the mode of the database file; they are checked
  after the switch to write-ahead logging and again after the migrations.
- An existing folder or file that allows more than the owner fails with `StoreError.insecurePermissions`; the
  entry is not changed. A database path that is a symbolic link or not a regular file is rejected.

## Version 1

`settings_values` holds the stored overrides.

| Column | Type | Notes |
|---|---|---|
| `key` | TEXT | catalog key |
| `scope` | TEXT | `global`, `family` or `principal` |
| `subject` | TEXT | family or principal name; empty exactly when the scope is `global` |
| `value` | TEXT | JSON scalar (integer, boolean or string) |

Primary key `(key, scope, subject)`.

`settings_audit` is the append-only trail of changes. Update and delete are refused by triggers, which guards
against mistakes in application code; it does not protect against someone who can edit the database file.

| Column | Type | Notes |
|---|---|---|
| `id` | INTEGER | autoincrement, defines the order |
| `at_ms` | INTEGER | time of the change from the injected clock, milliseconds since 1970 |
| `actor` | TEXT | who made the change, as passed by the caller; never empty |
| `key`, `scope`, `subject` | TEXT | the address that changed |
| `old_value` | TEXT | JSON of the value stored at exactly this address before; `NULL` when none was stored |
| `new_value` | TEXT | JSON of the new value |

A change writes the value and its audit row in one transaction.
