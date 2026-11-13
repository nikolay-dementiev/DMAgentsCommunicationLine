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

| `op` | Who | Arguments | Result |
|---|---|---|---|
| `send` | any | `to` list of principal ids, `subject`, `body` | `id` |
| `inbox` | any | `after` optional cursor | `entries` (list of `id`, `sender`, `subject`, `created_at_ms`), `next` (cursor or null) |
| `read` | any | `id` | `id`, `sender`, `family`, `recipients`, `subject`, `body`, `created_at_ms` |
| `acknowledge` | any | `id` | empty |
| `wait` | any | `timeout` optional, seconds, at least 0 | `outcome`: `mail` or `timeout` |
| `owner.credential` | none or owner | none | `token`. Without a token it issues the first owner credential; with the current owner token it replaces it |
| `principal.create` | owner | `family`, `role` (`head` or `agent`), `name` | `id`, `family`, `role`, `name`, `enabled` |
| `principal.disable` | owner | `principal` | empty |
| `principal.enable` | owner | `principal` | empty. A no-op for an enabled principal; a disabled one needs a new credential |
| `credential.issue` | owner | `principal` | `token` (shown once) |
| `grant.add` | owner | `reader_kind` (`principal`/`family`), `reader`, `target_kind` (`principal`/`family`/`global`), `target` (not for `global`), `expires_at_ms` optional | `id` |
| `grant.revoke` | owner | `id` | empty |
| `grant.list` | owner | none | `grants` (list of `id`, `reader_kind`, `reader`, `target_kind`, `target`, `expires_at_ms`, `revoked`) |
| `rule.add`, `rule.remove` | owner | `from`, `to` (families) | empty |
| `rule.list` | owner | none | `rules` (list of `from`, `to`) |
| `setting.get` | any, or owner | `key` | `key`, `value` (the value that applies to the caller) |
| `setting.set` | owner | `key`, `value`, `scope` optional (default `global`), `subject` for `family` and `principal` | `key` |

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
| `unknown_recipient` | not found | A recipient does not exist |
| `message_unavailable` | not found | No such message, or it may not be read by the caller (the same answer) |
| `unknown_grant` | not found | No such grant |
| `unknown_key` | not found | No such setting |
| `invalid_name` | invalid input | A blank family or name |
| `invalid_rule` | invalid input | A blank rule or grant field |
| `invalid_page_limit`, `invalid_setting` | invalid input | A messaging limit the catalog cannot supply |
| `no_recipients`, `subject_too_large`, `body_too_large` | invalid input | The message limits of [messaging](messaging.md) |
| `expiry_in_the_past` | invalid input | A grant that has already expired |
| `scope_not_allowed`, `subject_required`, `subject_not_allowed`, `invalid_value` | invalid input | A setting change the catalog refuses |
| `internal` | internal | Anything unexpected. The detail goes to the service's standard error, never to the caller |

## Known limits

- A parked `wait` authenticates when it starts; a token revoked meanwhile ends it only at its timeout.
- The number of parked waiters and connections is not bounded yet (planned with the quotas).
- `SO_RCVTIMEO` restarts on every received byte, so a client that sends one byte just inside the
  request timeout can hold a connection thread; there is no overall request deadline or connection
  cap yet (planned with the quotas).
- `stop()` is bounded by the grace periods only while no request is stuck in the store; a request
  blocked on an external writer can delay the close by up to the busy timeout.
- Any process of the same user that connects first after a fresh install can claim the owner
  credential with `owner.credential`; the installer should call it right after the first start.
- The service reads `store.busy_timeout` and `service.frame_max` once, at start.
