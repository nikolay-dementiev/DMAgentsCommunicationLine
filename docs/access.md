# Identity and access rules

New in v0.1 and open until the release. Basic mode: processes of the owner's account are mutually trusted,
so this layer keeps agents from acting as each other by mistake and from exceeding their rights. It does not
protect against a process that can read another agent's token or edit the database file.

## Credentials

- A token is 256 random bits from the system's secure generator, written as 43 characters of base64url
  without padding. It is returned once, when it is issued. The store keeps only its SHA-256 digest (64 hex
  characters) and the principal it belongs to.
- Two kinds exist: the owner's credential and a principal's credential. The owner has its own kind; an agent
  token is never accepted for an owner operation, and the owner's token is never a principal.
- `authenticate(token)` returns the owner or the principal. Three distinct errors say why it did not:
  `unknownToken`, `principalDisabled` and `tokenRevoked`. Digests are compared in constant time.
- The first owner credential is issued when none exists. Replacing it needs the current owner token; the old
  one is revoked. Two callers that race for the first credential, or rotate with the same token, cannot both
  succeed: one of them is refused with `ownerCredentialRequired`.
- Disabling a principal takes effect in the same transaction and revokes its credentials. Enabling it again
  never revives them: a new credential is required.
- Printing a token value shows `CredentialToken(redacted)`.

## Who acts

Every operation takes a token. The acting principal comes from the token, never from a value the caller
chooses. Settings reads use the family and id of the token's principal; the owner reads global values and
defaults. Changing a setting and reading its audit trail need the owner's token, and the audit actor of a
change is `owner`.

## Principals

A principal has an immutable id, an immutable family, a role (`head` or `agent`), a display name and an
enabled flag. Creating, disabling and enabling one are owner operations.

## Sending

- Within a family, sending is allowed.
- Across families it needs an owner send rule from the sender's family to the recipient's family. A rule in
  one direction does not allow the other.
- A disabled recipient never receives; the decision is `false`, so the failure is visible to the sender.
- A read grant never authorizes sending.

## Reading

A message is described by its sender, its original recipients and the sender's family. A principal can read it when it is:

1. the sender or an original recipient;
2. a `head` of the sender's family;
3. named by a read grant that is not revoked and not expired, either as a principal or by its family, **and**
   the grant's target covers the message.

A read grant names its reader and its target. The target says which mail the grant opens, and nothing else:

| Target | Opens |
|---|---|
| `principal` (an id) | the mail that principal sent or received |
| `family` (a name) | the mail sent by principals of that family |
| `global` | all mail; the owner has to ask for it explicitly, no grant defaults to it |

A disabled principal reads nothing. A grant expires at its expiry instant: reading at that instant is
refused. Observation does not acknowledge mail.

`canRead` and the policy trust the message description they are given. The code that sends and reads messages
must build it from the stored message, never from a request.

Limit of v0.1: a `head` sees messages whose sender is in its family. A message sent into its family from
another family is visible to that head only as a recipient or through a grant.

## Owner-only data

Send rules and read grants are read and changed only with the owner's token. A principal can ask only for
its own effective rights: its family, the families it may send to, and the grants that name it or its family.
