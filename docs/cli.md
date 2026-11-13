# The `commline` command

Status: open until the v0.1 release. The name is a working name.

```
commline (--store <folder> | --socket <path>) [--token-file <path>] [--json] <command> [options]
```

`--store` names the store folder of a running [service](service.md); the socket is `commline.sock` in it.
`--socket` names the socket directly. Exactly one of them is required.

## The token

A token is read from the file named by `--token-file`, or, without that option, from the first line of
standard input. It is **never** taken from an argument or from the environment, where other processes
could read it. `--token <value>` and `--token=<value>` are a usage error and nothing is sent.

A token file must be a regular file (not a link) owned by the caller, and must not be readable or
writable by group or others (mode 0600). Otherwise the command stops before it connects, with status 10.

`owner init` is the only command that needs no token.

## Commands

| Command | Token | Options and arguments |
|---|---|---|
| `owner init` | none | Issues the first owner credential. Prints the token |
| `owner rotate` | owner | Replaces the owner credential. Prints the new token |
| `principal create` | owner | `--family`, `--role head\|agent`, `--name`. Prints `id`, `family`, `role`, `name` |
| `principal disable <id>`, `principal enable <id>` | owner | |
| `credential issue <principal-id>` | owner | Prints the new token (shown once) |
| `rule add <from> <to>`, `rule remove <from> <to>`, `rule list` | owner | Family names |
| `grant add` | owner | `--reader-principal <id>` or `--reader-family <name>`; `--target-principal <id>`, `--target-family <name>` or `--target-global`; `--expires-at-ms <n>`. Prints the grant id |
| `grant revoke <id>`, `grant list` | owner | |
| `activity` | owner | `--after <cursor>`, `--limit <n>`. Prints one `id`, `at_ms`, `actor`, `operation`, `outcome`, `targets` (comma separated) line per record (tab separated) and `next: <cursor>` when more follow |
| `health` | owner | Prints the health report as text, or as the result document with `--json`. Works without any agent session |
| `health cleanup` | owner | Runs cleanup now. Prints `deliveries: <n>`, `messages: <n>` and `activity: <n>`: what it deleted |
| `setting get <key>` | any | Prints the value that applies to the caller |
| `setting set <key> <value>` | owner | `--scope global\|family\|principal`, `--subject <name>`. The value is an integer, `true`/`false`, or text |
| `send` | any | `--to <id>` (repeatable), `--subject`, and `--body <text>` or `--body-file <path>` |
| `inbox` | any | `--after <cursor>`. Prints one `id`, `sender`, `created_at_ms`, `subject` line per message (tab separated) and `next: <cursor>` when more follow |
| `read <message-id>` | any | Prints `From:`, `To:`, `Subject:`, an empty line and the body. Does not acknowledge |
| `acknowledge <message-id>` | any | |
| `agent add` | owner | `--family`, `--role head\|agent`, `--name`, `--client claude-code`, `--home`. Prints the principal id and the files written |
| `wait` | any | `--timeout <seconds>`. Prints `mail` or `timeout` |
| `wait --until-mail` | any | No time limit: repeats the cycles and reconnects after a service restart. Prints `mail` and exits 0 only when mail is pending. Not combinable with `--timeout` |

## Host commands

These act on the machine, not on the service, and need no `--store`, `--socket` or token option:

| Command | Options | What it does |
|---|---|---|
| `install` | `--home <folder>` | Installs the service for the caller. See [install](install.md) |
| `uninstall` | `--home <folder>`, `--delete-data` | Removes what the install wrote; keeps the store unless `--delete-data` and no mail is pending |
| `owner recover` | `--home <folder>` | Gives the owner a new token when the token file is lost or was never written. See [install](install.md) |

`agent add` (see [agents](agents.md)) needs `--store` and the owner token, and writes files under the store
folder and, for a client, under `--home`.

## Output

Standard output carries the result only; every diagnostic goes to standard error as
`commline: <code>: <message>`. A command with nothing to show prints `ok`.

With `--json` a result is printed as the JSON document of the [response](service.md) `result`, and a
failure as `{"error":{"code":"...","message":"..."}}` on standard error. The exit status is the same in
both modes.

## Health report

`commline health` prints, in this order: `started:` (milliseconds since 1970), `storage:` (bytes used of the budget
and the warning percent), one `warning: <name>` line per active warning (`storage_budget`), one `pending: <principal>`
and count line per principal with pending mail, `overdue: <count>` followed by one `message`, `recipient`,
`<age>s` line (tab separated) for each of the oldest overdue deliveries (at most `messaging.page_size`), and
`last cleanup:` with its time and the three counts, `failed` after the time when the run failed, or `none` when no
cleanup has run since the service started.

## Exit statuses

The table is stable. A failure is never 0.

| Status | Name | Meaning |
|---|---|---|
| 0 | success | The operation succeeded; for `wait`, mail is pending |
| 1 | failure | The service failed in a way it did not name (`internal`), or `commline` failed |
| 2 | usage | The command line is wrong. Nothing was sent |
| 3 | unreachable | Nothing is listening on the socket |
| 4 | authentication | `token_required`, `unknown_token`, `token_revoked`, `principal_disabled` |
| 5 | permission | `owner_required`, `agent_required`, `recipient_refused` |
| 6 | not found | `unknown_principal`, `unknown_recipient`, `message_unavailable`, `unknown_grant`, `unknown_key` |
| 7 | invalid input | A value the service refused (names, rules, limits such as `too_many_recipients`, settings, expiry) |
| 8 | protocol | `bad_request`, `frame_too_large`, `recipient_inbox_full`, `too_many_waiters`, or an answer that is not a response |
| 9 | timed out | `wait` ended without mail |
| 10 | token input | The token file is missing, unreadable, not private, or empty, or no token was supplied |
| 11 | not installed | `wait --until-mail` found no store folder: commline is not installed here, or was removed |
