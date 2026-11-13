# Agents: setup, instructions, mail command and waiter

Status: open until the v0.1 release. The file names are working names.

```
commline agent add --store <folder> --family <f> --role head|agent --name <n>
                   [--client claude-code] [--home <folder>] [--token-file <path>]
```

`agent add` needs the owner token (from `--token-file`, as for any owner command). It talks to the running
service and writes files; it prints the path of each file and never a token.

## What it creates

1. The principal, with the given family, role and name.
2. Its credential. The token is written to `<store>/agents/<id>.token` (mode 0600, created with `O_EXCL`;
   the folder `agents` is mode 0700).
3. The instruction file `<store>/agents/<id>.md` (mode 0600).
4. With `--client claude-code`, a mail command `<home>/.claude/commands/commline-<name>.md` (mode 0600),
   where `<name>` is the agent name in lower case with anything but letters and digits turned into a hyphen.
   The file is added to the install manifest, so `uninstall` removes it. `agent add` needs an install for
   this. It never overwrites a file that exists; it stops before creating anything.

Neither text contains a token. They name the token file, and every command in them reads the token from it.

## The instruction file

It says who the agent is (name, role, family, principal id), where its token file is, and lists the commands
with the installed `commline`, the store and the token file already filled in: `inbox`, `read`, `send`,
`acknowledge` and `wait --until-mail`. It states the rules:

- Reading a message never acknowledges it.
- Acknowledge a message after you have handled it, not before.
- Mail that is not acknowledged stays in the inbox.

## The mail command

For Claude Code, the file has a `description` header and four steps: list the inbox, read each message to
handle, handle it and then acknowledge it, and arm the waiter as a background command so that the session is
woken when mail arrives.

## The waiter

```
commline ... wait --until-mail
```

It has no time limit. It repeats `wait` cycles on its own and prints `mail` and exits 0 only when the caller
has pending mail. `--until-mail` cannot be combined with `--timeout`. It does not acknowledge anything.

| Situation | Behaviour |
|---|---|
| The `wait` cycle times out | starts the next cycle |
| The service is not reachable (a restart) | prints a note to standard error, pauses one second and tries again |
| The answer is not a valid response | pauses one second and tries again, without a note |
| The token is refused (unknown, revoked, principal disabled) | exits 4 |
| Any other failure the service names | exits with the status of its class (see [the command](cli.md)) |
| The store folder does not exist (commline is not installed here, or was removed) | exits 11 |
| Any other error of `commline` itself | exits 1 |
| The token file cannot be read | exits 10 |

Because it retries while the service is down and the store folder exists, a waiter outlives a service restart
or an upgrade. A service that is stopped for good while the store folder stays keeps the waiter retrying.
