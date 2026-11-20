# Service and socket protocol

Status: open until the v0.1 release. The names `commline-service` and `commline` are working names.

One service process, running as the owner's user, is the only opener of the database. Agents and the
owner reach it through a Unix-domain socket, usually with the `commline` command ([CLI](cli.md)).

## The process

```
commline-service <store-folder>
```

| Exit status | Meaning |
|---|---|
| 0 | Stopped cleanly after SIGTERM or SIGINT |
| 1 | Could not start (the reason is on standard error) |
| 2 | Usage error |
| 3 | Another instance is already running on this store |

Inside the store folder (created with mode 0700 when missing, refused when it is open to others):

| File | Mode | Purpose |
|---|---|---|
| `commline.sqlite` (+ `-wal`, `-shm`) | 0600 | The database |
| `commline.lock` | 0600 | Exclusive `flock`, held for the life of the process |
| `commline.sock` | 0600 | The listening socket |

- **One instance.** The lock is taken before the database is opened. A second instance exits with
  status 3 while the first holds it. The system releases the lock when the process dies, so a crashed
  instance never blocks a new one.
- **Stale socket.** After the lock is held, a socket file left by a dead instance is removed. Anything
  else at that path (a regular file, a socket of another user) stops the start.
- **Peer check.** Every accepted connection is checked with `getpeereid`. A peer whose effective user ID
  differs from the service's own is closed without an answer. The folder mode and the socket mode are
  the first barrier; this check is the second.
- **Stop.** SIGTERM or SIGINT stops accepting, removes the socket and answers every parked `wait` as
  timed out (outcome `timeout`). Requests that are running get up to two seconds to finish; the
  connections still open after that are shut down. Then the database is closed (the write-ahead log
  is folded into the database file) and the lock is released. The process exits only after all of
  this.
- **Path length.** A Unix-domain socket path is limited to 103 bytes on macOS; a longer store folder
  path cannot be used.
- **No network.** The service listens on the local socket only.

## Frames

One request frame and one response frame per connection; the service closes the connection after its
answer. A connection that sends no complete request within 10 seconds is dropped.

```
frame   = length payload
length  = 4 bytes, big endian, the size of payload (1 .. service.frame_max)
payload = one JSON document, UTF-8
```

A request or response nested deeper than 32 levels of arrays and objects is `bad_request`; this is
checked before decoding, so a frame of brackets cannot exhaust the stack of a connection thread.

A length above `service.frame_max` (default 2097152, read once at start; see [settings](settings.md)) is
answered with `frame_too_large` after the four length bytes, before any payload byte is read, and the
connection is closed. A frame of length zero or a frame that is not a request is `bad_request`.

## Request

```json
{"token": "<43 characters>", "op": "send", "args": {"to": ["<principal id>"], "subject": "s", "body": "b"}}
```

- `token`: the credential of the caller. It is read from this field and from nowhere else. An
  `args.token` is ignored. A missing token is `token_required`; a malformed one is `unknown_token`.
- `op`: the operation name. An unknown name is `bad_request`.
- `args`: the arguments; absent means none. Values are strings, integers (no fractions), booleans,
  null, arrays and objects.

## Response

```json
{"ok": true, "result": {...}}
{"ok": false, "error": {"code": "recipient_refused", "message": "..."}}
```

`ok` is true with a `result` and no `error`, or false with an `error` and no `result`. Anything else is
not a response. Messages are for people; scripts test `code`.

## Operations

Instants are whole milliseconds since 1970. "Owner" means the owner token is required (`owner_required`
otherwise). "Any" means a principal token; the owner token is refused by the message operations.
"Owner or observer" means the owner token or the read-only observer token (see [access](access.md)); an
observer is refused every operation that is not marked so, with a permission error (`owner_required` or
`agent_required`).

| `op` | Who | Arguments | Result |
|---|---|---|---|
| `send` | any | `to` list of principal ids, `subject`, `body` | `id` |
| `inbox` | any | `after` optional cursor | `entries` (list of `id`, `sender`, `subject`, `created_at_ms`), `next` (cursor or null) |
| `read` | any | `id` | `id`, `sender`, `family`, `recipients`, `subject`, `body`, `created_at_ms` |
| `acknowledge` | any | `id` | empty |
| `wait` | any | `timeout` optional, seconds, at least 0 | `outcome`: `mail` or `timeout` |
| `owner.credential` | none or owner | none | `token`. Without a token it issues the first owner credential; with the current owner token it replaces it |
| `principal.create` | owner | `family`, `role` (`head` or `agent`), `name` | `id`, `family`, `role`, `name`, `enabled` |
| `principal.list` | owner or observer | `family` optional | `principals` (list of `id`, `family`, `role`, `name`, `enabled`, `pending`, `listening_since_ms`, which is `null` when no `wait` of the principal is parked). Sorted by family, role, name. `unknown_family` when `family` has no principal |
| `principal.disable` | owner | `principal` | empty |
| `principal.enable` | owner | `principal` | empty. A no-op for an enabled principal; a disabled one needs a new credential |
| `credential.issue` | owner | `principal` | `token` (shown once) |
| `grant.add` | owner | `reader_kind` (`principal`/`family`), `reader`, `target_kind` (`principal`/`family`/`global`), `target` (not for `global`), `expires_at_ms` optional | `id` |
| `grant.revoke` | owner | `id` | empty |
| `grant.list` | owner | none | `grants` (list of `id`, `reader_kind`, `reader`, `target_kind`, `target`, `expires_at_ms`, `revoked`) |
| `rule.add`, `rule.remove` | owner | `from`, `to` (families) | empty |
| `rule.list` | owner | `family` optional: only the rules that send from it or into it | `rules` (list of `from`, `to`) |
| `setting.get` | any, or owner | `key` | `key`, `value` (the value that applies to the caller) |
| `setting.set` | owner | `key`, `value`, `scope` optional (default `global`), `subject` for `family` and `principal` | `key` |
| `activity.list` | owner | `after` optional cursor (the id of the last record seen), `limit` optional, 1 to `messaging.page_size` | `records` (list of `id`, `at_ms`, `actor`, `operation`, `outcome`, `targets`), `next` (cursor, absent on the last page) |
| `health` | owner or observer | `family` optional: `pending`, `overdue`, `not_listening_with_pending` and `principals` keep only that family's recipients; `unknown_family` when it has no principal | The [health document](health.md), a stable contract |
| `health.cleanup` | owner | none | `deliveries`, `messages`, `activity`: how many rows the run deleted |
| `observer.issue` | owner | none | `token` (shown once). Replaces the observer token that was issued before |
| `observer.revoke` | owner | none | empty. Succeeds when no observer token exists |

`wait` blocks the connection. It returns `mail` as soon as the caller has pending mail (also mail that
was pending when it was called) and `timeout` when the time runs out. The time is capped by
`messaging.wait`; zero returns at once. Semantics of the message operations are in
[messaging](messaging.md), the rules behind `owner_required` and the grants in [access](access.md).

## Error codes

Each code belongs to one class; the CLI maps the class to its exit status.

| Code | Class | Raised when |
|---|---|---|
| `bad_request` | request | Unknown operation, missing or mistyped argument, not a request |
| `frame_too_large` | request | The frame is larger than `service.frame_max` |
| `token_required` | authentication | The request carries no token |
| `unknown_token` | authentication | The token is not known or is malformed |
| `token_revoked` | authentication | The credential was revoked |
| `principal_disabled` | authentication | The principal is disabled |
| `owner_required` | permission | The operation needs the owner token |
| `agent_required` | permission | The operation needs a principal token |
| `recipient_refused` | permission | The send policy refuses a recipient |
| `unknown_principal` | not found | No such principal |
| `unknown_family` | not found | The family named in `family` has no principal |
| `unknown_recipient` | not found | A recipient does not exist |
| `message_unavailable` | not found | No such message, or it may not be read by the caller (the same answer) |
| `unknown_grant` | not found | No such grant |
| `unknown_key` | not found | No such setting |
| `invalid_name` | invalid input | A blank family or name |
| `invalid_rule` | invalid input | A blank rule or grant field |
| `invalid_page_limit`, `invalid_setting` | invalid input | A messaging limit the catalog cannot supply |
| `no_recipients`, `subject_too_large`, `body_too_large` | invalid input | The message limits of [messaging](messaging.md) |
| `too_many_recipients` | invalid input | A message with more distinct recipients than `wire.recipients` |
| `recipient_inbox_full` | request | A recipient already has `quota.messages.assigned_per_principal` pending deliveries. Nothing is stored and nothing is deleted |
| `too_many_waiters` | request | The caller or the service already has the most parked waits `limits.waits.principal` / `limits.waits.global` allow |
| `too_many_connections` | request | The service has no free place for the request: the connection came after the places left to agents were taken and the request is not one an owner may make on a reserve place, or no reserve place is free (see [Connections](#connections-and-descriptors)). Nothing was done; try again shortly |
| `storage_full` | request | The database has reached `storage.refusal_percent` of `storage.budget`, so `send` is refused. Reading, acknowledging, waiting, cleanup and every owner operation keep working; cleanup frees space and the refusal ends by itself |
| `expiry_in_the_past` | invalid input | A grant that has already expired |
| `scope_not_allowed`, `subject_required`, `subject_not_allowed`, `invalid_value` | invalid input | A setting change the catalog refuses |
| `internal` | internal | Anything unexpected. The detail goes to the service's standard error, never to the caller |

## Activity log

Every request the service handles leaves one record: the time from the service clock, the actor (`owner`,
`observer`, `unauthenticated` or `principal:<id>`), the operation, the outcome (`ok` or the error code) and the ids it touched.
Refused and failed requests are recorded, and so are the owner credential bootstrap and its replacement. The record
of a request that succeeds is written in the transaction of its effect; a request that fails leaves no effect and is
recorded afterwards. A `wait` is recorded when it ends, and so is `health.cleanup`: both are recorded after their work is done, outside any transaction, so a record that cannot be written (disk full, for example) is reported on standard error and never undoes the work or the answer.

Flood control. A client that sends refused requests in a loop would otherwise fill the log. A refusal is recorded at most once per `limits.activity.refusal_window` seconds for each outcome (the error code); the first record after the window lists how many were left out as the target `suppressed:<n>`. With the window at 0 every refusal is recorded. Only refusals are throttled; a request that succeeds, and any other failure, is always recorded. A second bound is the number of rows: cleanup deletes the oldest records beyond `retention.activity.max_rows`. A token, a subject, a body or the text of an unknown
operation name is never recorded. A connection answered `too_many_connections` before its request reaches the dispatcher leaves no record, so that a flood of connections cannot fill the log. The log is append-only; only retention deletes from it. The schema is in
[schema](schema.md).

## Retention and cleanup

Cleanup runs every `cleanup.interval` seconds and when the owner sends `health.cleanup`. In one transaction it
deletes the deliveries of each message whose deliveries are all acknowledged and whose newest acknowledgement is
more than `retention.messages.live` days old (a message with a pending delivery keeps all of them), then the
messages that have no delivery left, then activity older than `retention.activity.live` days and activity beyond the newest `retention.activity.max_rows` records. Pending mail is never deleted: a
trigger in the database refuses it, independently of this code. A failed scheduled run is reported on standard error
and tried again at the next interval. The service remembers the last run (time and counts, or that it failed) for the
health report; the memory lasts as long as the process. The run is committed first and recorded in the activity log afterwards; when the record cannot be written, the cleanup still counts as done and the health report says so (`cleanup_not_recorded`).

## Health report

`health` is for the owner and for the observer, and needs no agent session. Its result is the
[health document](health.md), version 1: every field, its type and the stability rule are listed there and
checked by a test. `health.threshold` applies per recipient: the principal's own value, then its family's,
then the global one. An acknowledged delivery is never overdue.

With no service listening, `commline health --json` fails at once with exit status 3 and an error document;
see [health](health.md#when-the-service-is-not-there).

## Limits

| Limit | Key | Refusal |
|---|---|---|
| Recipients per message | `wire.recipients` | `too_many_recipients` |
| Pending deliveries per recipient | `quota.messages.assigned_per_principal` | `recipient_inbox_full` |
| Parked waits per principal and in all | `limits.waits.principal`, `limits.waits.global` | `too_many_waiters`. Only a wait that would park needs a place; one that finds mail at once does not |
| Open connections | `limits.connections` | `too_many_connections`. See [Connections and descriptors](#connections-and-descriptors) |
| Connections kept for the owner | `limits.connections.owner_reserve` | A connection past the places left to agents is served only for an owner request, and only while a reserve place is free; anything else gets `too_many_connections` |
| Time to send a request and to receive the answer | `service.request_deadline` | The connection is closed. It counts from the accept to the last byte of the request, so a client that trickles bytes cannot hold a thread; writing the response has the same bound, so a client that does not read cannot hold one either. A parked `wait` is not cut off: its request was complete |
| Database size | `storage.budget`, `storage.refusal_percent` | `storage_full` for `send` |
| Activity log | `retention.activity.max_rows`, `limits.activity.refusal_window` | Oldest rows are deleted by cleanup; repeated refusals are recorded once per window |
| Re-authentication of a parked `wait` | `messaging.wait_recheck` | A parked wait checks its token at least every this many seconds; a revoked or disabled token ends it with `token_revoked` or `principal_disabled` |

## Connections and descriptors

The service raises its soft limit of open files (`RLIMIT_NOFILE`) at start as far as the hard limit and the system allow (`kern.maxfilesperproc`). A connection can hold up to three descriptors (the socket and what watches it while a `wait` is parked) and the service keeps 64 for itself, so the limit in force gives at most `(limit - 64) / 3` connections. When `limits.connections` is larger than that, the service uses the smaller number and writes a line to standard error under the operation `descriptor limit`; it does not stop.

A connection past the limit is accepted only to be refused: the service reads its request and answers `too_many_connections` at once, so the client learns the reason instead of seeing a closed socket. A small number of such refusals is held at a time; beyond it the connection is closed without an answer.

Owner reserve. `limits.connections` places are shared in two parts: `limits.connections` minus `limits.connections.owner_reserve` places for any connection, and the reserve. A connection that arrives when the first part is taken is held only to read its first request, and is called unclassified until that request arrives. If the request is an owner request (not `send`, `inbox`, `read`, `acknowledge` or `wait`) and a reserve place is free, it is served and the place is given back afterwards; any other request is answered `too_many_connections` at once. Idle connections therefore never hold a reserve place, because a place is taken by a request and not by a connection. The observer's `health` and `principal.list` count as owner requests here and use a reserve place for one request; an observer `wait` is answered with a refusal and never parks.

The bound for the owner. At most 16 connections are held unclassified. When a new connection arrives and all 16 are taken, the service shuts down the oldest unclassified one to make room, so a process that connects and sends nothing cannot keep the owner out: the owner's connection is admitted at once and answered within one request, after at most 0.25 s spent waiting for a closed connection to leave. A connection that sends nothing is closed after 2 seconds (or `service.request_deadline` when that is shorter). At most 32 connections past the limit are held in all; beyond that a new connection is closed without an answer. The reserve is read at start and is cut down so that at least one place is left to agents.

## Known limits

- A parked `wait` re-checks its token every `messaging.wait_recheck` seconds, not at the moment of revocation: a token revoked meanwhile ends the wait within that interval.
- While a `wait` is parked the service watches the connection. When the client disconnects (end of stream or hang-up) the wait ends at once and gives back its thread, its connection place and its waiter slot; the answer is dropped and the wait is still recorded in the activity log. A client therefore must not close its sending side after the request: it sends one request and only reads until the answer.
- Beyond a small number of connections refused at the same time the service closes the connection without an answer; the client sees it closed.
- `limits.connections.owner_reserve` is read at start; changing it needs a restart.
- A process that connects and sends nothing is shut down when it is the oldest of the 16 unclassified connections, and after 2 seconds in any case; it can still make every other new connection past the limit wait up to 0.25 s for room. The service has no per-process limit.
- An owner request takes a reserve place for as long as it runs. The classification is by operation name before the token is checked, so a request with a made-up name or no token also takes a place briefly.
- Health scans every pending delivery older than the moment of the call to find the overdue ones, because the
  threshold can differ per principal. The scan is bounded by the pending quota of each principal.
- The memory of the last cleanup is lost when the service restarts.
- `stop()` is bounded by the grace periods only while no request is stuck in the store; a request
  blocked on an external writer can delay the close by up to the busy timeout.
- Any process of the same user that connects first after a fresh install can claim the owner
  credential with `owner.credential`; the installer should call it right after the first start.
- The service reads `store.busy_timeout`, `service.frame_max`, `cleanup.interval`, `limits.connections` and
  `service.request_deadline` once, at start.
