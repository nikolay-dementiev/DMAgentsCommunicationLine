# Messaging

Agents send, list, read, acknowledge and wait for mail through the application layer, on the SQLite store.
Every operation takes the caller's token and derives the caller from it; no operation takes a sender or a
recipient identity as a claim about the caller.

All of this is new and open until the v0.1 release.

## Send

`send(token:to:subject:body:)` takes principal credentials only.

- The recipients are made distinct, keeping the order given.
- A message needs at least one recipient and at most `wire.recipients`. The subject and the body must fit `messaging.subject_max` and
  `messaging.body_max` (UTF-8 bytes). Nothing is stored when a check fails.
- One transaction reads the sender, the recipients and the send rules, applies the send policy to every recipient,
  and stores the message with one pending delivery per recipient. A principal disabled, or a rule removed, after the
  caller was authenticated therefore still takes effect.
- A recipient that already has `quota.messages.assigned_per_principal` pending deliveries refuses the send
  (`recipient_inbox_full`). Nothing is stored for any recipient, and no old mail is deleted to make room; the sender
  must wait until the recipient acknowledges some.
- If one recipient is refused, nothing is stored and the error names that recipient. An unknown recipient is a
  different error from a refused one.
- After the commit, the arrival interface is signalled for the recipients.

## Inbox

`inbox(token:after:)` lists the caller's pending deliveries, oldest first, `messaging.page_size` at a time. Each
entry has the message id, the sender, the subject and the time, not the body. The page carries a cursor for the
next page, or none after the last. The cursor is a position in the delivery order, never a saved read state.

## Read

`read(token:messageID:)` returns the message when the access rules allow the caller to read it. The decision is
built from the stored message, its sender's family and its stored deliveries, never from anything the caller
supplies. A message that does not exist and a message the caller may not read give the same error. Reading never
acknowledges.

## Acknowledge

`acknowledge(token:messageID:)` marks the caller's own delivery. Only a recipient can; anyone else gets the same
error as for a missing message. Repeating it succeeds and keeps the first time. It never touches another
recipient's delivery.

## Pending protection

No operation deletes or rewrites a delivery. The database refuses it too (see `schema.md`, version 3), so a raw
statement or a future bug cannot drop pending mail. Pending mail survives closing and reopening the store.

## Wait

`wait(token:timeout:)` returns `mail` at once when the caller has pending mail. Otherwise it parks until mail for the
caller is committed, or until the timeout runs out and it returns `timedOut`. The timeout defaults to
`messaging.wait` and never exceeds it; a catalog value of zero turns parking off.

Nothing polls. A waiter takes a ticket from the arrival interface before it looks at its inbox, so a send that lands
in between is not lost. After every wake the inbox is checked again, so a signal that finds nothing pending does
not end the wait early.

`MailArrival` is the interface; v0.1 of this layer ships `InProcessMailArrival`, which wakes waiters in the same
process. The cross-process implementation replaces it behind the same interface.

## Threads

One `SQLiteStore` may be shared by several threads, for example a parked waiter and a sender in one process. Every
statement and every whole transaction runs as one unit, so another thread never sees the uncommitted rows of an open
transaction. Separate processes use separate connections and rely on `BEGIN IMMEDIATE` and the busy timeout.

## Known limits of this layer

- There is no owner operation to expire pending mail: pending mail is never deleted, so a recipient that never
  acknowledges holds its place in its quota and in the database until the owner disables the principal.
- The send error distinguishes an unknown recipient from a refused one, so a leaked principal id can be probed.
- A parked wait authenticates once, when it starts.
- Family names are compared as Swift strings and stored as given; only the owner creates them.
