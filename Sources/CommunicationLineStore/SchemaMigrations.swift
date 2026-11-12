/// The numbered schema steps of the product. Released versions never change; add a new step instead.
public enum SchemaMigrations {
  public static let all: [Migration] = [version1]

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
}
