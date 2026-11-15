# CommunicationLine 0.2.0 (in progress)

Version 0.2 moves every agent family onto commline. This file grows with each step; the version number in the
programs does not change until the release.

## W1: who exists and who listens

The owner can see who exists in each family and who is listening right now.

- `commline principal list [--family <name>]` prints one line per principal: id, family, role, name, `enabled` or
  `disabled`, `pending <n>` and `listening since <ms>` or `not listening`. `--json` prints an array of objects.
- `commline rule list --family <name>` keeps only the rules that send from the family or into it.
- `commline health --family <name>` keeps `pending` and `overdue` to the recipients of the family. Storage,
  warnings, the start time and the last cleanup stay global. A new line, `not listening with pending: <n>`, counts
  the principals that have pending mail and no parked `wait`; it appears with and without `--family`.
- A `--family` with no principal is refused with exit status 6 and `no principal in family <name>` for
  `principal list` and `health`.
- Wire: the operation `principal.list`, the optional `family` argument of `rule.list` and `health`, the result
  field `not_listening_with_pending` of `health` and the error code `unknown_family` (not found).

All of these need the owner token; an agent token is refused. No token appears in any output.

The listening state lives in the memory of the service. It is not stored, does not survive a restart, and a waiter
that reconnects after a restart is listening again. It says that a `wait` is parked, not that the session behind
it is alive. The text form is not yet a stable contract; the JSON form becomes stable in W3.

## W2: limits for many agents

The service keeps working with many agents, and the owner can always reach it.

- Connections: past `limits.connections` a client is answered `too_many_connections` instead of seeing the socket
  closed. The service raises its open-file limit at start and fits `limits.connections` under it; when the
  configured number does not fit it uses the smaller one and writes a line to standard error.
- Owner reserve: `limits.connections.owner_reserve` keeps places that only the owner's operations can use, so a
  flood of agent requests cannot lock the owner out.
- Deadline: `service.request_deadline` now also bounds writing the response, so a client that does not read
  cannot hold a thread.
- Parked waits re-check their token every `messaging.wait_recheck` seconds; a revoked or disabled token ends the
  wait within that time.
- Storage: at `storage.refusal_percent` of `storage.budget` `send` is refused with `storage_full`; everything else,
  cleanup included, keeps working. The health report shows the field `storage.refusal_percent` and the warning
  `storage_full`.
- Activity log: repeated refusals are recorded once per `limits.activity.refusal_window`, with a `suppressed:<n>`
  count, and cleanup keeps at most `retention.activity.max_rows` records. The records of `wait` and
  `health.cleanup` are written after the work, so a full disk cannot undo a finished cleanup; when the cleanup
  record is lost, `health` warns `cleanup_not_recorded`.
- Inbox quota: schema version 7 keeps a count of pending deliveries per recipient, read under the write lock, so
  two concurrent sends cannot go over `quota.messages.assigned_per_principal`.
- `commline agent add` runs one after another when started together: the manifest is read and written under a lock.

New error codes, both of class request (exit status 8): `too_many_connections`, `storage_full`. New settings keys:
`limits.connections.owner_reserve`, `retention.activity.max_rows`, `limits.activity.refusal_window`,
`storage.refusal_percent`, `messaging.wait_recheck`. Contracts stay open until the 0.2 release.

Known limits of v0.1 that this closes: no flood control for the activity log; no reserve of connection slots for the
owner; no storage budget that refuses writes; parked waits not re-authenticated; the pending count not taken under
the write lock; cleanup on a full disk (the cleanup record no longer rolls the cleanup back); the unlocked manifest
update in `agent add`.
