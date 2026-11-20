# The health document, version 1

`health` (wire operation `health`, command `commline health --json`) returns one document that a
program which is not an agent, such as a dashboard, can read. This page is the only list of its
fields. A test compares the document the service produces with the table below, so a field that is
removed, renamed or retyped in the code, or in this page alone, fails the build.

## Stability rule

The document has a version, the integer field `version`. This page describes version 1.

- Within version 1 fields are only added. A reader ignores a field it does not know.
- Renaming or removing a field, or changing its type or its meaning, needs version 2.
- The wire operation and the command line keep their other contracts (see [service](service.md)
  and [cli](cli.md)).

## Fields

A path with `[]` names a field of every element of an array. A type with `or null` can be `null`.
A field marked `(optional)` is absent in some documents, as the meaning says.

| Field | Type | Meaning |
|---|---|---|
| `version` | integer | The version of this document: `1` |
| `started_at_ms` | integer | When the service started, in milliseconds since 1970-01-01 UTC |
| `pending` | array | One entry per principal with pending mail |
| `pending[].principal` | string | The id of the principal |
| `pending[].count` | integer | How many deliveries wait for it |
| `not_listening_with_pending` | integer | How many principals have pending mail and no `wait` parked for them |
| `overdue_count` | integer | All deliveries pending longer than `health.threshold` |
| `overdue` | array | The oldest `messaging.page_size` of them |
| `overdue[].message` | string | The id of the message |
| `overdue[].recipient` | string | The id of the recipient |
| `overdue[].age_seconds` | integer | Whole seconds since the message was sent |
| `storage` | object | The database against its budget |
| `storage.used_bytes` | integer | Pages in use, not the free ones |
| `storage.budget_bytes` | integer | `storage.budget` |
| `storage.warning_percent` | integer | From this share of the budget on, `storage_budget` is a warning |
| `storage.refusal_percent` | integer | From this share of the budget on, `send` is refused with `storage_full` |
| `principals` | array | Every principal (with `--family`, those of that family), sorted by family, role and name, as `principal.list` shows them |
| `principals[].id` | string | The id of the principal |
| `principals[].family` | string | Its family |
| `principals[].role` | string | `agent` or `head` |
| `principals[].name` | string | Its display name |
| `principals[].enabled` | bool | Whether the principal may use its credentials |
| `principals[].pending` | integer | Deliveries to it that nobody has acknowledged |
| `principals[].listening_since_ms` | integer or null | When its oldest parked `wait` started, in milliseconds since 1970-01-01 UTC; `null` when none is parked. The state lives in the memory of the service |
| `warnings` | array | The current warnings, which clear by themselves when the state does |
| `warnings[]` | string (optional) | `storage_budget`, `storage_full` or `cleanup_not_recorded`; present when there is a warning |
| `last_cleanup` | object or null | The last cleanup run since the service started; `null` before the first |
| `last_cleanup.at_ms` | integer | When it ran, in milliseconds since 1970-01-01 UTC |
| `last_cleanup.ok` | bool | Whether it completed |
| `last_cleanup.deliveries` | integer (optional) | Rows deleted; present when `ok` |
| `last_cleanup.messages` | integer (optional) | Rows deleted; present when `ok` |
| `last_cleanup.activity` | integer (optional) | Rows deleted; present when `ok` |

## Example

```json
{
  "version": 1,
  "started_at_ms": 1800000000000,
  "pending": [{"principal": "7f0c2d5e", "count": 1}],
  "not_listening_with_pending": 1,
  "overdue_count": 1,
  "overdue": [{"message": "b3a41c0d", "recipient": "7f0c2d5e", "age_seconds": 1860}],
  "storage": {"used_bytes": 163840, "budget_bytes": 5000000000, "warning_percent": 80, "refusal_percent": 95},
  "principals": [
    {"id": "7f0c2d5e", "family": "ops", "role": "agent", "name": "worker", "enabled": true, "pending": 1, "listening_since_ms": null}
  ],
  "warnings": [],
  "last_cleanup": {"at_ms": 1800000000000, "ok": true, "deliveries": 0, "messages": 0, "activity": 0}
}
```

## When the service is not there

With no service listening, `commline health --json` returns at once, without retrying, with exit
status 3 and an error document on standard error:

```json
{"error": {"code": "service_unreachable", "message": "the service is not reachable: ..."}}
```

`service_unreachable` is a code of the command line, not of the wire: the service sends no answer
in that case.
