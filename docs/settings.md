# Settings catalog

The catalog is the single place where a shipped tunable number is written:
`Sources/CommunicationLineStore/Resources/settings-defaults.json`. Product code reads defaults from the
catalog and never repeats them. The catalog is new and open until the first release.

## Resource format

`{"settings": [ ... ]}`, one entry per key:

| Field | Meaning |
|---|---|
| `key` | dotted name, unique; by convention lower case with underscores inside a part |
| `type` | `integer`, `duration`, `bytes`, `boolean` or `enum` |
| `unit` | optional unit text of a numeric value (`seconds`, `days`, `bytes`, ...) |
| `default` | integer, boolean or string, valid for the entry's own type and range |
| `range` | optional `{"min": n, "max": n}`; either bound may be omitted |
| `values` | the allowed strings of an `enum` |
| `scopes` | the scopes that may hold a value: `global`, `family`, `principal` |
| `description` | what the setting controls |

Loading refuses text that is not a valid catalog resource (`SettingsCatalogError.malformed`), an unknown type
or scope, a duplicate key, and a default that is not valid for its own definition.

## Effective value

The value that applies to a caller is the first of: the stored principal value, the stored family value, the
stored global value, the default. A stored value in a scope that the key does not allow is ignored.

## Changes

A change names an address (key, scope and, for family and principal, the subject), a value and an actor. The
service checks that the key exists, the scope is allowed, the subject matches the scope, the actor is not
blank and the value fits the type and range. It then writes the value and an audit row in one transaction.
Deciding who may change a setting is not part of this layer.

## Keys of this version

| Key | Type | Default | Range | Scopes |
|---|---|---|---|---|
| `store.busy_timeout` | duration, milliseconds | 5000 | 0..60000 | global |
| `retention.messages.live` | duration, days | 90 | 1..3650 | global |
| `retention.activity.live` | duration, days | 90 | 1..3650 | global |
| `cleanup.interval` | duration, seconds | 300 | 1..300 | global |
| `storage.budget` | bytes | 5000000000 | at least 1 | global |
| `storage.warning_percent` | integer, percent | 80 | 1..98 | global |
| `health.threshold` | duration, seconds | 1800 | 60..86400 | global, family, principal |
| `messaging.wait` | duration, seconds | 900 | 0..900 | global |
| `messaging.subject_max` | bytes | 512 | 1..512 | global |
| `messaging.body_max` | bytes | 262144 | 1..262144 | global |
| `messaging.page_size` | integer, messages | 100 | 1..100 | global |
| `wire.recipients` | integer, recipients | 32 | 1..256 | global |
| `quota.messages.assigned_per_principal` | integer, deliveries | 100000 | 1..1000000 | global |
| `limits.waits.global` | integer, waits | 128 | 0..4096 | global |
| `limits.waits.principal` | integer, waits | 2 | 0..64 | global |
| `limits.connections` | integer, connections | 256 | 1..4096 | global |
| `service.request_deadline` | duration, seconds | 10 | 1..300 | global |
| `limits.connections.owner_reserve` | integer, connections | 8 | 0..1024 | global |
| `retention.activity.max_rows` | integer, records | 1000000 | 1000..100000000 | global |
| `limits.activity.refusal_window` | duration, seconds | 60 | 0..3600 | global |
| `storage.refusal_percent` | integer, percent | 95 | 1..100 | global |
| `messaging.wait_recheck` | duration, seconds | 5 | 1..60 | global |
| `service.frame_max` | bytes | 2097152 | 4096..16777216 | global |

`messaging.wait` is the default and the maximum time a wait may stay parked; zero turns parked waits off, so a wait only reports pending mail.
The subject and body limits count UTF-8 bytes. The three `messaging.*` size keys are v0.1 proposals that split the
`wire.text` limits of the design into one key each; they are open until the v0.1 release.
`service.frame_max` is a v0.1 proposal too: the largest frame on the service socket. The default admits a message at
the size limits even when every character is escaped in JSON. The service reads it once, at start.

Where the design has a row, the v0.1 key uses its name and default:

| Key | Design row |
|---|---|
| `retention.messages.live`, `retention.activity.live`, `cleanup.interval` | SPEC-SETTINGS rows of the same names (`cleanup.interval` is a periodic interval, range 1..300 seconds) |
| `storage.budget`, `storage.warning_percent`, `health.threshold` | SPEC-SETTINGS rows of the same names |
| `wire.recipients` | SPEC-SETTINGS `wire.recipients`, default 32. The range 1..256 is a v0.1 proposal |
| `quota.messages.assigned_per_principal` | The `assigned_per_principal` member (100000) of the composite `quota.messages` row. A v0.1 proposal that makes it a key of its own |
| `limits.waits.global`, `limits.waits.principal` | The `global` (128) and `principal` (2) members of the composite `limits.waits` row. A v0.1 proposal that makes each a key of its own. Zero admits no parked wait |

`limits.connections` and `service.request_deadline` have no design row and are v0.1 proposals. A connection past
`limits.connections` is answered `too_many_connections` and closed. `service.request_deadline` is the time a client has to send its
whole request, counted from the accept, and to take the answer; the per-read timeout alone cannot stop a client that sends one byte at a time.
`cleanup.interval`, `limits.connections` and `service.request_deadline` are read once, at start. A zero in the design
means "disabled"; the v0.1 ranges for these three start at 1.

The keys added in 0.2 (W2) are v0.2 proposals and stay open until the 0.2 release:

- `limits.connections.owner_reserve`: how many of `limits.connections` agents cannot take (see [service](service.md#connections-and-descriptors)). Read once, at start. Zero keeps nothing back; the service always leaves at least one place to agents.
- `retention.activity.max_rows`: cleanup deletes the oldest activity records beyond this number, whatever their age.
- `limits.activity.refusal_window`: a refusal with the same outcome is recorded once per window, the next record names how many were left out. Zero records every refusal.
- `storage.refusal_percent`: from this share of `storage.budget`, `send` is refused with `storage_full`. Keep it above `storage.warning_percent` so the warning comes first; the service does not enforce the order.
- `messaging.wait_recheck`: how often a parked wait checks that its principal may still read.
The retention keys count whole days from the time of the newest acknowledgement of a message (mail: a message with several recipients is judged when all of them have acknowledged) or of the request (activity).
