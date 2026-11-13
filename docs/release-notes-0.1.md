# CommunicationLine 0.1.0

Version 0.1.0 lets AI agent sessions on one Mac exchange mail through a shared SQLite database instead of
Markdown mailbox files. `commline --version` and `commline-service --version` print `0.1.0`.

## What it does

- A background service (a LaunchAgent under your account) owns the database and answers on a private Unix socket.
- `commline` sends, lists, reads and acknowledges mail, and waits for it. Reading never acknowledges.
- Agents belong to families and have a role (`head` or `agent`). Sending stays inside a family unless the owner
  adds a send rule; reading is limited to the sender, the recipients and the head of the sender's family unless the
  owner grants more. Every credential is a token kept in a file at mode 0600.
- Mail that nobody acknowledged is never deleted by retention, cleanup or `uninstall --delete-data`.
- `commline wait --until-mail` parks until mail arrives, survives a service restart, and exits 0 only when mail is pending.
- Settings live in a table with a catalog of keys, types and defaults; changes are audited. An activity log and a
  `health` report are included.
- `commline agent add` creates an agent, its token file, an instruction file and, for Claude Code, a mail command.
- `commline owner recover` replaces a lost owner token without the old one and without the network.

## Trust in this release

Basic mode only. Every agent runs as you, so an agent can read the token file of any other agent and the owner
token, and act in their name. Use 0.1 for mutually trusted local agents. The token files keep other accounts out,
not other agents of the same account.

## Install, upgrade, uninstall

```
commline install [--home <folder>]
commline install                      # again: an upgrade, the database and owner token are kept
commline uninstall [--home <folder>]  # keeps the store
commline uninstall --delete-data      # removes the store only when no mail is pending
```

Details, paths and exit statuses: [install](install.md). Agents: [agents](agents.md). Commands: [cli](cli.md).
Install and uninstall refuse to run as root. Contracts (schema version 6, commands, file formats) stay open until
this release is published.

## Known limits

Planned for 0.2 or later:

- no flood control for the activity log;
- no reserve of connection slots for the owner;
- no storage budget that refuses writes (the warning only reports);
- parked waits are not re-authenticated while they wait;
- the count of pending mail per recipient is not taken under the write lock;
- cleanup does not run on a full disk;
- the manifest update in `agent add` is not locked, so two concurrent runs can drop a command entry;
- the install does not check whether the last folder of a path is a symbolic link;
- backticks or newlines in `--home` can break the generated instruction text;
- `wait --until-mail` keeps retrying while the service is gone for good;
- an owner recovery is not written to the activity log.
- text output does not escape the zero-width and directional marks U+200B to U+200F, U+061C, U+2060 and U+FEFF;
- `uninstall` and `owner recover` assume the service runs under launchd; a service started by hand is not stopped first
  (`uninstall --delete-data` refuses while such a service holds the store lock, and deletes nothing);
- install and uninstall follow symbolic links in the parent folders of the paths they write, and check only the
  last component of each path. Basic mode trusts the account; the usual case is a dotfile repository that links
  `~/Library` or `~/.claude`, which works as expected;
- a failed upgrade can leave the old service stopped; run `commline install` again;
- a database that already holds a row with id -1 in `activity` or `settings_audit` is not repaired by the version 6
  migration (versions 4 and 5 were never released, so only a development database can be affected);
- a `--token-out` file is removed by name, and a command killed by a signal between the request and the write leaves
  an empty 0600 file (remove it and, for the owner, run `commline owner recover`);
- each parked wait holds three descriptors and two threads; keep `limits.connections` well below the descriptor limit
  of the service (often 256 under launchd);
- `uninstall --delete-data` takes no lock when the store folder is missing at that moment;
- the client deadline covers reads and connects, not a write larger than the socket buffer to a peer that never reads;
- files are renamed into place without `fsync`, so a power loss right after an install can leave an empty file;
  run `commline install` again;
- `launchctl print` failures other than "not found" (for example no graphical session) now stop install and uninstall with an error.
