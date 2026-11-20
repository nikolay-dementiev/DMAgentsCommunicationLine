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
- Owner reserve: `limits.connections.owner_reserve` keeps places that only an owner request can use, taken by a
  request and not by a connection, so neither a flood of agent requests nor idle connections can lock the owner
  out for longer than one request deadline.
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

Known limits of W2:

- A refusal is recorded once per window for each outcome, not for each actor, so one noisy client can hide the
  same outcome from another inside the window; only the count of the hidden ones is kept. Keying by actor is not
  done in 0.2.
- Continuous integration builds with the Xcode 26.6 of the `macos-26` image (Swift 6.3). The development
  machine uses Swift 6.4; the image has no Xcode with Swift 6.4, so the code is kept buildable on 6.3 and CI
  does not select another toolchain.

## W3: a stable health document and a read-only token

A program that is not an agent can watch the system.

- The health document is version 1 and a contract: [health](health.md) lists every field. Within the version
  fields are only added; a test compares the document with that page in both directions. New fields: `version`
  and `principals` (the same entries as `principal list`, so a dashboard needs one call).
- Presence: each principal in the document shows `listening_since_ms`, the start of its oldest parked `wait`, or
  `null`.
- `commline health --json` with no service listening exits 3 at once, without retrying, with
  `{"error":{"code":"service_unreachable",...}}` on standard error.
- The observer credential: `commline observer issue --token-out <path>` and `commline observer revoke`. The token
  reads `health` and `principal list` and nothing else; it is not a principal. Wire: `observer.issue`,
  `observer.revoke`. Schema version 8 adds the table `observer_credential`.
- The owner can always reach the service: a connection that sends nothing is closed after 2 seconds and, when 16
  of them are waiting, the oldest is shut down for a newcomer, so a process that opens connections and stays silent
  no longer keeps the owner out (this closes the W2 limit on connections held to be classified). At most 32
  connections past the limit are held (16 before).
- The agent share of the connection places is pinned by a test: with the default reserve, agents can park only
  `limits.connections` minus `limits.connections.owner_reserve` waits.

No new error codes and no new settings keys. Every request of an observer is recorded in the activity log under
the actor `observer`, a successful read included. Contracts stay open until the 0.2 release.
- The connection deadlines (`service.request_deadline` and the classification deadline) run on a timer thread of the
  service, not on the shared dispatch pool, so a busy or blocked pool can no longer delay a cut. Before this a
  runner with the pool full of blocked work never cut a silent connection.

Known limits of W3:

- A request with any non-agent operation name takes an owner reserve place before its token is checked, so a
  process of the same user that loops `health` can keep reserve places busy for longer than the owner's own
  requests need. The service has no per-process limit.
- The oldest silent connection is closed first, whoever it belongs to: under a flood the owner's own half-sent
  request can be the one closed, and the command line then tries again.
- `observer.issue` is serialised by the store's write lock; there is no test that runs two issues at once.
