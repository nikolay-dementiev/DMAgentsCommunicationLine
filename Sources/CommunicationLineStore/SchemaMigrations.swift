/// The numbered schema steps of the product. Released versions never change; add a new step instead.
public enum SchemaMigrations {
  public static let all: [Migration] = [version1, version2, version3]

  /// Version 1: stored settings and their append-only audit trail.
  private static let version1 = Migration(
    version: 1,
    statements: [
      """
      CREATE TABLE settings_values (
        key TEXT NOT NULL,
        scope TEXT NOT NULL CHECK (scope IN ('global', 'family', 'principal')),
        subject TEXT NOT NULL,
        value TEXT NOT NULL,
        PRIMARY KEY (key, scope, subject),
        CHECK ((scope = 'global') = (subject = ''))
      ) WITHOUT ROWID
      """,
      """
      CREATE TABLE settings_audit (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        at_ms INTEGER NOT NULL,
        actor TEXT NOT NULL CHECK (actor <> ''),
        key TEXT NOT NULL,
        scope TEXT NOT NULL CHECK (scope IN ('global', 'family', 'principal')),
        subject TEXT NOT NULL,
        old_value TEXT,
        new_value TEXT NOT NULL
      )
      """,
      "CREATE INDEX settings_audit_by_key ON settings_audit (key, id)",
      """
      CREATE TRIGGER settings_audit_no_update BEFORE UPDATE ON settings_audit
      BEGIN SELECT RAISE(ABORT, 'settings_audit is append-only'); END
      """,
      """
      CREATE TRIGGER settings_audit_no_delete BEFORE DELETE ON settings_audit
      BEGIN SELECT RAISE(ABORT, 'settings_audit is append-only'); END
      """,
    ])

  /// Version 2: principals, credential digests, owner read grants and cross-family send rules.
  private static let version2 = Migration(
    version: 2,
    statements: [
      """
      CREATE TABLE principals (
        id TEXT PRIMARY KEY CHECK (id <> ''),
        family TEXT NOT NULL CHECK (family <> ''),
        role TEXT NOT NULL CHECK (role IN ('head', 'agent')),
        display_name TEXT NOT NULL CHECK (display_name <> ''),
        enabled INTEGER NOT NULL CHECK (enabled IN (0, 1)),
        created_at_ms INTEGER NOT NULL
      ) WITHOUT ROWID
      """,
      """
      CREATE TRIGGER principals_identity_is_immutable BEFORE UPDATE OF id, family, role ON principals
      BEGIN SELECT RAISE(ABORT, 'a principal id, family and role never change'); END
      """,
      """
      CREATE TABLE credentials (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        digest TEXT NOT NULL UNIQUE CHECK (length(digest) = 64),
        kind TEXT NOT NULL CHECK (kind IN ('owner', 'principal')),
        principal_id TEXT REFERENCES principals (id),
        issued_at_ms INTEGER NOT NULL,
        revoked_at_ms INTEGER,
        CHECK ((kind = 'owner') = (principal_id IS NULL))
      )
      """,
      "CREATE INDEX credentials_by_principal ON credentials (principal_id)",
      """
      CREATE UNIQUE INDEX credentials_one_active_owner ON credentials (kind)
      WHERE kind = 'owner' AND revoked_at_ms IS NULL
      """,
      """
      CREATE TABLE read_grants (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        reader_kind TEXT NOT NULL CHECK (reader_kind IN ('principal', 'family')),
        reader TEXT NOT NULL CHECK (reader <> ''),
        target_kind TEXT NOT NULL CHECK (target_kind IN ('principal', 'family', 'global')),
        target TEXT NOT NULL CHECK ((target_kind = 'global') = (target = '')),
        expires_at_ms INTEGER,
        created_at_ms INTEGER NOT NULL,
        revoked_at_ms INTEGER
      )
      """,
      """
      CREATE TABLE send_rules (
        from_family TEXT NOT NULL CHECK (from_family <> ''),
        to_family TEXT NOT NULL CHECK (to_family <> ''),
        created_at_ms INTEGER NOT NULL,
        PRIMARY KEY (from_family, to_family),
        CHECK (from_family <> to_family)
      ) WITHOUT ROWID
      """,
    ])

  /// Version 3: messages and one delivery per recipient. A pending delivery cannot be deleted.
  private static let version3 = Migration(
    version: 3,
    statements: [
      """
      CREATE TABLE messages (
        seq INTEGER PRIMARY KEY AUTOINCREMENT,
        id TEXT NOT NULL UNIQUE CHECK (id <> ''),
        sender TEXT NOT NULL REFERENCES principals (id),
        subject TEXT NOT NULL,
        body TEXT NOT NULL,
        created_at_ms INTEGER NOT NULL
      )
      """,
      """
      CREATE TABLE deliveries (
        message_seq INTEGER NOT NULL REFERENCES messages (seq),
        recipient TEXT NOT NULL REFERENCES principals (id),
        state TEXT NOT NULL CHECK (state IN ('pending', 'acknowledged')),
        acknowledged_at_ms INTEGER,
        PRIMARY KEY (message_seq, recipient),
        CHECK ((state = 'acknowledged') = (acknowledged_at_ms IS NOT NULL))
      )
      """,
      "CREATE INDEX deliveries_by_recipient ON deliveries (recipient, state, message_seq)",
      """
      CREATE TRIGGER deliveries_pending_cannot_be_deleted
      BEFORE DELETE ON deliveries WHEN OLD.state = 'pending'
      BEGIN
        SELECT RAISE(ABORT, 'a pending delivery cannot be deleted');
      END
      """,
      """
      CREATE TRIGGER deliveries_acknowledged_is_final
      BEFORE UPDATE ON deliveries WHEN OLD.state = 'acknowledged'
      BEGIN
        SELECT RAISE(ABORT, 'an acknowledged delivery cannot be changed');
      END
      """,
      """
      CREATE TRIGGER deliveries_pending_only_becomes_acknowledged
      BEFORE UPDATE ON deliveries
      WHEN OLD.state = 'pending'
        AND (NEW.state <> 'acknowledged' OR NEW.message_seq <> OLD.message_seq
          OR NEW.recipient <> OLD.recipient)
      BEGIN
        SELECT RAISE(ABORT, 'a pending delivery can only be acknowledged');
      END
      """,
      """
      CREATE TRIGGER messages_with_a_pending_delivery_cannot_be_deleted
      BEFORE DELETE ON messages
      WHEN EXISTS (SELECT 1 FROM deliveries WHERE message_seq = OLD.seq AND state = 'pending')
      BEGIN
        SELECT RAISE(ABORT, 'a message with a pending delivery cannot be deleted');
      END
      """,
      """
      CREATE TRIGGER messages_cannot_be_replaced
      BEFORE INSERT ON messages
      WHEN EXISTS (SELECT 1 FROM messages WHERE seq = NEW.seq OR id = NEW.id)
      BEGIN
        SELECT RAISE(ABORT, 'a stored message cannot be replaced');
      END
      """,
      """
      CREATE TRIGGER deliveries_cannot_be_replaced
      BEFORE INSERT ON deliveries
      WHEN EXISTS (
        SELECT 1 FROM deliveries WHERE message_seq = NEW.message_seq AND recipient = NEW.recipient)
      BEGIN
        SELECT RAISE(ABORT, 'a stored delivery cannot be replaced');
      END
      """,
      """
      CREATE TRIGGER messages_are_immutable
      BEFORE UPDATE ON messages
      BEGIN
        SELECT RAISE(ABORT, 'a message cannot be rewritten');
      END
      """,
    ])
}
