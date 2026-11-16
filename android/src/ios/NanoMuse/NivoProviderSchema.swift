import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CNivoSQLite
#endif

/// 提供商数据库的首次建库和历史补列共用事务，失败不得留下已升级的版本标记。
enum NivoProviderSchema {
    static let version: Int32 = 2

    /// 建库先完成全部表，再进行幂等补列；较新数据库保持原有版本号。
    static func migrate(_ database: OpaquePointer) throws {
        guard let current = try NivoSQLiteWrite.readRow(database, sql: "PRAGMA user_version",
            decode: { sqlite3_column_int($0, 0) }) else { throw NivoPersonalBackupError.invalidPackage }
        try NivoSQLiteWrite.transaction(database) {
            if current < 1 {
                for statement in initialTables { try NivoSQLiteWrite.execute(database, sql: statement) }
            }
            for statement in additiveTables { try NivoSQLiteWrite.execute(database, sql: statement) }
            try ensureColumns(database, table: "provider_instances", definitions: [
                ("custom_user_agent", "TEXT"), ("azure_mode", "INTEGER NOT NULL DEFAULT 0"),
            ])
            try ensureColumns(database, table: "provider_model_groups", definitions: [
                ("removed_members_json", "TEXT NOT NULL DEFAULT '{}'"),
                ("added_members_json", "TEXT NOT NULL DEFAULT '{}'"),
            ])
            if current < version {
                try NivoSQLiteWrite.execute(database, sql: "PRAGMA user_version = \(version)")
            }
        }
    }

    private static func ensureColumns(_ database: OpaquePointer, table: String,
                                       definitions: [(String, String)]) throws {
        let columns = try NivoSQLiteWrite.readRows(database, sql: "PRAGMA table_info(\(table))") { statement in
            guard let value = sqlite3_column_text(statement, 1) else { throw NivoPersonalBackupError.invalidPackage }
            return String(cString: value)
        }
        guard !columns.isEmpty else { throw NivoPersonalBackupError.invalidPackage }
        let existing = Set(columns)
        for (column, type) in definitions where !existing.contains(column) {
            try NivoSQLiteWrite.execute(database, sql: "ALTER TABLE \(table) ADD COLUMN \(column) \(type)")
        }
    }

    private static let initialTables = [
        """
        CREATE TABLE IF NOT EXISTS provider_instances (
            id                       TEXT PRIMARY KEY,
            label                    TEXT NOT NULL,
            provider_type            TEXT NOT NULL,
            credential_type          TEXT,
            custom_base_url          TEXT,
            append_v1_suffix         INTEGER NOT NULL DEFAULT 1,
            image_endpoint_mode      TEXT,
            image_endpoint_resolved  TEXT,
            custom_user_agent        TEXT,
            azure_mode               INTEGER NOT NULL DEFAULT 0,
            is_enabled               INTEGER NOT NULL DEFAULT 1,
            sort_order               INTEGER NOT NULL DEFAULT 0,
            secret_blob              TEXT,
            secret_kind              TEXT,
            secret_updated_at        REAL,
            created_at               REAL NOT NULL,
            updated_at               REAL NOT NULL,
            extras_json              TEXT
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS provider_model_entries (
            id                       TEXT PRIMARY KEY,
            provider_instance_id     TEXT NOT NULL,
            base_model_json          TEXT NOT NULL,
            overrides_json           TEXT,
            is_custom                INTEGER NOT NULL DEFAULT 0,
            is_hidden                INTEGER NOT NULL DEFAULT 0,
            user_modified_at         REAL,
            sort_order               INTEGER NOT NULL DEFAULT 0,
            updated_at               REAL NOT NULL,
            extras_json              TEXT,
            FOREIGN KEY(provider_instance_id) REFERENCES provider_instances(id) ON DELETE CASCADE
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_entries_instance ON provider_model_entries(provider_instance_id)",
        """
        CREATE TABLE IF NOT EXISTS provider_model_groups (
            id                       TEXT PRIMARY KEY,
            name                     TEXT NOT NULL,
            strategy                 TEXT NOT NULL,
            fallback_strategy        TEXT NOT NULL,
            default_thinking_level   TEXT,
            context_limit_tokens     INTEGER,
            context_limit_remembered INTEGER,
            member_entry_ids_json    TEXT NOT NULL,
            sort_order               INTEGER NOT NULL DEFAULT 0,
            updated_at               REAL NOT NULL,
            extras_json              TEXT,
            removed_members_json     TEXT NOT NULL DEFAULT '{}',
            added_members_json       TEXT NOT NULL DEFAULT '{}'
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS provider_local_kv (
            key   TEXT PRIMARY KEY,
            value TEXT
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS provider_session_bindings (
            session_id    TEXT PRIMARY KEY,
            binding_json  TEXT NOT NULL,
            updated_at    REAL NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS provider_session_inference_configs (
            session_id    TEXT PRIMARY KEY,
            config_json   TEXT NOT NULL,
            updated_at    REAL NOT NULL
        )
        """,
    ]

    private static let additiveTables = [
        """
        CREATE TABLE IF NOT EXISTS provider_agent_loop_ids (
            kind       TEXT NOT NULL,
            target_id  TEXT NOT NULL,
            sort_order INTEGER NOT NULL,
            PRIMARY KEY (kind, target_id)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS provider_thinking_rules (
            id                TEXT PRIMARY KEY,
            instance_id       TEXT NOT NULL,
            sort_order        INTEGER NOT NULL,
            scope_kind        TEXT NOT NULL,
            scope_pattern     TEXT,
            wire_format_json  TEXT NOT NULL,
            echo_field        TEXT,
            echo_timing       TEXT,
            label             TEXT NOT NULL DEFAULT '',
            is_builtin        INTEGER NOT NULL DEFAULT 0,
            created_at        REAL NOT NULL DEFAULT 0,
            updated_at        REAL NOT NULL DEFAULT 0
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_thinking_rules_instance ON provider_thinking_rules (instance_id, sort_order)",
    ]
}
