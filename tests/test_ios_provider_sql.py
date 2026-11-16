"""直接执行iOS生产源码中的SQL，验证提供商更新不删除其已有模型。"""

import re
import sqlite3
from pathlib import Path


SOURCE = (
    Path(__file__).resolve().parents[1]
    / "android/src/ios/Providers/ProviderConfigDB.swift"
).read_text(encoding="utf-8")
SCHEMA = (
    Path(__file__).resolve().parents[1]
    / "android/src/ios/NanoMuse/NivoProviderSchema.swift"
).read_text(encoding="utf-8")


def create_statement(table: str) -> str:
    """读取生产建表语句，不为回归重写外键关系。"""
    match = re.search(
        rf"CREATE TABLE (?:IF NOT EXISTS )?{table} \(.*?\n\s*\)", SCHEMA, re.S
    )
    assert match is not None
    return match.group()


def instance_upsert() -> str:
    """读取生产行写入函数的SQL正文。"""
    body = SOURCE.split("private func upsertInstanceRow(", maxsplit=1)[1]
    match = re.search(r'let sql = """(.*?)"""', body, re.S)
    assert match is not None
    return match.group(1)


def rule_cache_query() -> str:
    """读取生产规则缓存查询，核对乱序抵达与父记录删除后的筛选。"""
    body = SOURCE.split("func nmThinkingRuleCacheSnapshot()", maxsplit=1)[1]
    match = re.search(r'let sql = """(.*?)"""', body, re.S)
    assert match is not None
    return match.group(1)


def test_provider_update_preserves_models_and_explicit_delete_still_cascades():
    """更新提供商保留模型，用户明确删除提供商时仍清理其模型。"""
    database = sqlite3.connect(":memory:")
    try:
        database.execute("PRAGMA foreign_keys=ON")
        database.execute(create_statement("provider_instances"))
        database.execute(create_statement("provider_model_entries"))
        values = [
            "provider", "original", "openai", "apiKey", None, 1, None, None,
            1, 0, None, None, None, 1.0, 1.0, None, None, 0,
        ]
        database.execute(instance_upsert(), values)
        database.execute(
            "INSERT INTO provider_model_entries "
            "(id, provider_instance_id, base_model_json, updated_at) "
            "VALUES (?, ?, ?, ?)",
            ("provider/model", "provider", '{"id":"model"}', 1.0),
        )
        values[1] = "changed"
        values[14] = 2.0
        database.execute(instance_upsert(), values)
        assert database.execute(
            "SELECT id FROM provider_model_entries"
        ).fetchall() == [("provider/model",)]
        assert database.execute(
            "SELECT label, updated_at FROM provider_instances"
        ).fetchone() == ("changed", 2.0)
        database.execute("DELETE FROM provider_instances WHERE id='provider'")
        assert database.execute(
            "SELECT COUNT(*) FROM provider_model_entries"
        ).fetchone() == (0,)
    finally:
        database.close()


def test_rule_cache_uses_persisted_parents_and_keeps_rule_order():
    """缓存从数据库读取父记录，排除失去父记录的规则并保留顺序。"""
    database = sqlite3.connect(":memory:")
    try:
        database.execute(create_statement("provider_instances"))
        database.execute(create_statement("provider_thinking_rules"))
        database.execute(
            "INSERT INTO provider_instances "
            "(id, label, provider_type, created_at, updated_at) "
            "VALUES ('provider', 'fixture', 'openai', 1, 1)"
        )
        for identifier, parent, order in [
            ("later", "provider", 2),
            ("earlier", "provider", 1),
            ("orphan", "missing", 0),
        ]:
            database.execute(
                "INSERT INTO provider_thinking_rules "
                "(id, instance_id, sort_order, scope_kind, wire_format_json, "
                "label, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, 1, 1)",
                (identifier, parent, order, "allModels",
                 '{"kind":"omitEverything"}', "fixture"),
            )
        assert [row[0] for row in database.execute(rule_cache_query())] == [
            "earlier", "later"
        ]
        database.execute("DELETE FROM provider_instances")
        assert database.execute(rule_cache_query()).fetchall() == []
    finally:
        database.close()


def test_fresh_group_schema_supports_current_member_history_reads():
    """首次建库即可读取当前缓存必需列，不能依赖第二次启动补列。"""
    database = sqlite3.connect(":memory:")
    try:
        database.execute(create_statement("provider_model_groups"))
        database.execute(
            "INSERT INTO provider_model_groups "
            "(id, name, strategy, fallback_strategy, member_entry_ids_json, "
            "updated_at) VALUES ('group', 'fixture', 'fallback', 'limited', "
            "'[]', 1)"
        )
        assert database.execute(
            "SELECT added_members_json, removed_members_json "
            "FROM provider_model_groups"
        ).fetchone() == ("{}", "{}")
    finally:
        database.close()
