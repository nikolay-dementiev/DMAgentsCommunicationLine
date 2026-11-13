# Install, upgrade and uninstall

Status: open until the v0.1 release. The label and the paths below are working names.

```
commline install   [--home <folder>]
commline uninstall [--home <folder>] [--delete-data]
```

`--home` names the home folder to work in. Without it, the home folder of the caller is used. Every path
below is relative to that folder, and nothing outside it is written or removed.

Both commands run under your own account and refuse an effective user id of 0. There is no `sudo` and
no extra operating system account. On macOS the service is a LaunchAgent of the logged-in user.

## What `install` does

In this order:

1. Checks that `commline` and `commline-service` sit in the folder of the running `commline`.
2. If a manifest exists (an earlier install), unloads the running service.
3. Creates the folders and the database, and migrates the schema.
4. Copies the two programs, and the resource bundles named `CommunicationLine_*.bundle` that sit next to
   them (the service reads its defaults from one), into the program folder. A file is written next to
   its target and renamed over it, so a reader never sees half a file.
5. Writes the LaunchAgent plist.
6. Writes the manifest.
7. Loads the plist with `launchctl bootstrap gui/<uid>`.
8. Waits up to 15 seconds for the socket to answer. A service that never starts fails the install with a
   non-zero status and an error that names the service log. The install does not wait longer.
9. If `owner.token` does not exist yet, issues the owner credential and writes it there. The command
   prints the path of the file, never the token.

## What it writes

| Path | Mode | Content |
|---|---|---|
| `Library/Application Support/commline/bin/commline` | 0755 | the command |
| `Library/Application Support/commline/bin/commline-service` | 0755 | the service |
| `Library/Application Support/commline/bin/CommunicationLine_*.bundle/` | as copied | resource bundles the service reads |
| `Library/Application Support/commline/store/` | 0700 | the store folder |
| `Library/Application Support/commline/store/commline.sqlite` (+ `-wal`, `-shm`) | 0600 | the database |
| `Library/Application Support/commline/store/commline.sock` | 0600 | the service socket |
| `Library/Application Support/commline/store/service.log` | 0600 | standard output and error of the service |
| `Library/Application Support/commline/store/owner.token` | 0600 | the owner token, created once with `O_EXCL` |
| `Library/Application Support/commline/manifest.json` | 0600 | every file and registration the install made |
| `Library/LaunchAgents/com.commline.service.plist` | 0644 | the LaunchAgent |
| `.claude/commands/commline-<name>.md` | 0600 | a mail command, only when `agent add --client claude-code` wrote one |

The plist has the label `com.commline.service`. It runs `commline-service <store folder>` at load, restarts it
after a crash but not after a clean stop (`KeepAlive` with `SuccessfulExit` false), and sends both logs to
`service.log`. It has no environment and no token.

The manifest is JSON with `version`, `files` (absolute paths), `folders` (absolute paths of folders
removed with everything inside), `registrations` (`{launchAgent: {label, userID}}`) and `storeFolder`. The
store folder is never listed in `files`: it holds the data.

## Upgrade

Running `install` again is an upgrade. It replaces the programs, the bundles, the plist and the manifest,
and starts the service again, which runs any pending migration. It keeps the database and `owner.token`,
so pending mail survives and no second owner credential is issued. If the service has an owner credential
but `owner.token` is missing, the install stops with an error and does not replace the credential.

## Uninstall

`commline uninstall` stops the service (`launchctl bootout`), then removes exactly what the manifest lists:
the plist, the programs, the bundles, the command files and the manifest itself, which goes last so that an
interrupted run can be repeated. It never removes a path the manifest does not list. The manifest is only a
list: uninstall refuses (and removes nothing) when an entry is not one the install writes (the programs, the plist,
a `commline-*.md` command, a `CommunicationLine_*.bundle` under the program folder, the store folder) or is a
symbolic link. It keeps the store folder, with the database and all
tokens, and prints its path.

`--delete-data` also removes the store folder, but only when no delivery is pending. It counts the pending
mail before it changes anything and again after the service has stopped. If any mail is pending it refuses,
prints the count and removes nothing. Acknowledge the mail first, or keep the data. If mail arrives while the service is stopping, the
command refuses after the service was stopped; run `commline install` to start it again. The store is removed
before the manifest, so a failed `--delete-data` can be repeated.

Installing again on a kept store reuses the database and the owner token.

## Recovering the owner token

If `owner.token` is lost, or install failed after the credential was issued but before the file was
written, run:

```
commline owner recover [--home <folder>]
```

It needs no token and no network. It stops the service, revokes every live owner credential in the
database, issues a new one, writes it to `owner.token` at mode 0600 (replacing the file) and starts the
service again. It prints the path, never the token. The previous owner token stops working; agent tokens
are not touched. It refuses to run as root and when commline is not installed. If it fails after the
service was stopped, run it again; it is safe to repeat. Anyone who can read the store folder can already
do this, so it adds no access that the account does not have. The recovery is not recorded in the
activity log.

## Trust in this release

The basic mode of v0.1 has no separation between agents of one account. Every agent runs as you, so an
agent can read the token file of any other agent, and the owner token, and act in their name. Use v0.1 for
mutually trusted local agents only. The tokens are files at mode 0600 in folders at mode 0700: that keeps
other accounts out, not other agents of the same account.

## Exit statuses

`install` and `uninstall` exit 0 on success and 1 on any failure, with the reason on standard error. Usage
errors exit 2.
