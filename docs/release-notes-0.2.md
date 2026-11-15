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
