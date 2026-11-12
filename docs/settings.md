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
| `storage.budget` | bytes | 5000000000 | at least 1 | global |
| `storage.warning_percent` | integer, percent | 80 | 1..98 | global |
| `health.threshold` | duration, seconds | 1800 | 60..86400 | global, family, principal |
| `messaging.wait` | duration, seconds | 900 | 0..900 | global |
