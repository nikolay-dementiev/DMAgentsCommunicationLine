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
- Opening is safe when several processes start at once, also under a umask that removes the owner's
  write bit:
  - the setup phase runs under an exclusive `flock` on the store folder (SQLite locks the database
    file itself, so the file is not used for this);
  - a process that finds a folder or file another process is still creating waits until the owner has
    access, for at most the busy timeout;
  - the schema version is read again inside each migration transaction;
  - the switch to write-ahead logging is retried while another process holds the file, up to the
    busy timeout.
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

## Version 2

Principals, credentials and owner-managed rights. All of it is new and open until the v0.1 release.

| Table | Columns | Rules |
|---|---|---|
| `principals` | `id` (primary key), `family`, `role` (`head` or `agent`), `display_name`, `enabled` (0 or 1), `created_at_ms` | A trigger refuses any update of `id`, `family` or `role`. Only `enabled` changes, and only through an owner operation. |
| `credentials` | `id`, `digest` (unique, 64 hex characters), `kind` (`owner` or `principal`), `principal_id` (foreign key), `issued_at_ms`, `revoked_at_ms` | `kind = 'owner'` exactly when `principal_id` is null. A unique partial index allows at most one live (not revoked) owner credential. The table holds the SHA-256 digest of a token, never the token. |
| `read_grants` | `id`, `reader_kind` (`principal` or `family`), `reader`, `target_kind` (`principal`, `family` or `global`), `target` (empty exactly when the kind is `global`), `expires_at_ms` (nullable), `created_at_ms`, `revoked_at_ms` (nullable) | A grant is valid while not revoked and before its expiry instant, and opens only the mail its target names. |
| `send_rules` | `from_family`, `to_family` (primary key together), `created_at_ms` | A rule lets the first family send to the second, in that direction only. A family cannot have a rule to itself. |

Disabling a principal clears `enabled` and sets `revoked_at_ms` on all its credentials in one transaction.
Enabling it again sets `enabled` and, in the same transaction, revokes any credential of the principal that is still live; the old credentials stay revoked, so it needs a new one. Issuing a credential checks `enabled` and inserts in one transaction, so a credential cannot be issued to a principal that is being disabled. Replacing the owner credential is a compare-and-swap in one transaction: it succeeds only if the live owner credential is the one the caller authenticated with (or none exists, for the first one).

## Version 3

Messages and their deliveries. All of it is new and open until the v0.1 release.

| Table | Columns | Rules |
|---|---|---|
| `messages` | `seq` (integer primary key, the delivery order), `id` (unique, random), `sender` (foreign key to `principals`), `subject`, `body`, `created_at_ms` | A message is never rewritten (trigger). A message with a pending delivery cannot be deleted (trigger, independent of the foreign-key pragma). |
| `deliveries` | `message_seq` (foreign key), `recipient` (foreign key), `state` (`pending` or `acknowledged`), `acknowledged_at_ms` (nullable); primary key (`message_seq`, `recipient`) | One row per recipient, created with the message in one transaction. `acknowledged_at_ms` is set exactly when the state is `acknowledged`. |

Inserts that would replace an existing message or delivery (`INSERT OR REPLACE`, which SQLite runs without firing the
delete and update triggers) are refused by `BEFORE INSERT` triggers. These triggers guard against the API, a future bug
and accidental statements; they are not a defence against someone who holds the database file and can drop them.

Triggers on `deliveries`: a pending delivery cannot be deleted; a pending delivery can only change to `acknowledged`
(its message and recipient never change); an acknowledged delivery cannot be changed. An acknowledged delivery may be
deleted, which is how retention will reclaim it. Index `deliveries_by_recipient` serves the inbox.

## Version 4

The activity log. New and open until the v0.1 release.

| Table | Columns | Rules |
|---|---|---|
| `activity` | `id` (integer primary key, autoincrement, so the order of the log), `at_ms`, `actor`, `operation`, `outcome`, `targets` | Append-only: a trigger refuses every UPDATE and every INSERT that would replace a stored id (`INSERT OR REPLACE`). A DELETE is refused too unless the gate is open. The guarantee holds against the service and ordinary SQL, not against someone who can edit the file and drop triggers. |
| `activity_retention_gate` | `id` (always 1), `open` (0 or 1) | One row. Only the retention path opens it, inside the transaction that deletes, and closes it again before the commit. |

- `actor` is `owner`, `unauthenticated` or `principal:<id>`. A request whose token is missing, unknown, revoked or
  belongs to a disabled principal is `unauthenticated`.
- `operation` is the protocol operation name, or `unknown` for a name the service does not know (the name itself is
  never copied, because a client chose it).
- `outcome` is `ok` or the error code of the refusal or failure.
- `targets` is a JSON array of ids (message, principal, grant, rule families, setting key). It never holds a token,
  a subject or a body. At most 16 targets of at most 128 characters each are kept.
- Index `activity_by_time` serves retention.
- An ordinary request writes its record in the transaction of its effect, so neither exists without the other. A
  refused or failed request rolls back and is recorded afterwards. A `wait` is recorded when it ends.
- Nested transactions use savepoints on the same connection, so cleanup can run inside the transaction of the owner
  operation that asked for it.

## Version 5

New and open until the v0.1 release.

| Trigger | Rule |
|---|---|
| `settings_audit_cannot_be_replaced` | An insert into `settings_audit` that reuses a stored id is refused, so `INSERT OR REPLACE` cannot rewrite an audit record. The same guarantee as the activity log: it holds against the service and ordinary SQL, not against someone who can edit the file and drop triggers. |

## Version 6

New and open until the v0.1 release.

| Trigger | Rule |
|---|---|
| `activity_id_is_never_minus_one` | An insert that leaves the id -1 in `activity` is rolled back. In a BEFORE INSERT trigger SQLite shows `NEW.id` as -1 when the insert gave no id, so a stored row with id -1 would make the replace guard of version 4 refuse every later insert. |
| `settings_audit_id_is_never_minus_one` | The same for `settings_audit` and the guard of version 5. |

Version 6 does not repair a database that already holds a row with id -1 in `activity` or `settings_audit`. Such a row could only be written by an explicit insert, and versions 4 and 5 were never released, so only a development database can carry one; it has to be recreated.

## Version 7

New and open until the v0.2 release.

| Object | Rule |
|---|---|
| table `pending_counts` | One row per recipient: `recipient` (primary key) and `count` (at least 0), the number of its pending deliveries. `WITHOUT ROWID`. A recipient with no row has no pending delivery |
| trigger `deliveries_count_a_new_pending` | After an insert of a delivery in state `pending`, adds 1 to the recipient's count (creating the row) |
| trigger `deliveries_count_an_acknowledged` | After a delivery changes from `pending` to `acknowledged`, subtracts 1 |

The migration fills `pending_counts` from the deliveries that are pending when it runs. The inbox quota reads this row inside the write transaction that stores the message, so the check and the insert cannot be separated by another writer and the quota does not scan the deliveries.

## Version 8

New and open until the v0.2 release.

| Object | Rule |
|---|---|
| table `observer_credential` | One row per observer token ever issued: `id`, `kind` (always `observer`), `digest` (SHA-256 of the token, 64 hex characters, unique), `issued_at_ms` and `revoked_at_ms` (`NULL` while the token is live) |
| index `observer_credential_one_live` | Unique on `kind` where `revoked_at_ms IS NULL`: at most one live observer token exists |

The observer token is kept apart from `credentials` because every row there other than the owner's belongs to a principal, and an observer is not one: it has no family, no inbox and no id that mail can be sent to. Issuing a new observer token revokes the live one in the same transaction. Existing credentials are not touched, and a migrated database starts with no observer token.
