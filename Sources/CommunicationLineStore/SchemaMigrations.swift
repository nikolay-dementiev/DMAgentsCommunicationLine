/// The numbered schema steps of the product. Released versions never change; add a new step instead.
public enum SchemaMigrations {
  public static let all: [Migration] = [version1, version2]

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
      CREATE TABLE read_grants (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        reader_kind TEXT NOT NULL CHECK (reader_kind IN ('principal', 'family')),
        reader TEXT NOT NULL CHECK (reader <> ''),
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
}
