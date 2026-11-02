"""Channel settings (config.toml + the app's file + the vault) and the pairing store."""

from __future__ import annotations

import json
import time
from pathlib import Path

import pytest

from nanomuse.channels.base import Channel, Field
from nanomuse.channels.store import (
    CODE_ALPHABET,
    CODE_LENGTH,
    ChannelSettingsStore,
    PairingStore,
    new_code,
    vault_name,
)
from nanomuse.config import Settings
from nanomuse.vault.vault import CredentialVault


class Demo(Channel):
    name = "demo"
    label = "Demo"
    fields = (
        Field("app_id", "App ID", required=True),
        Field("app_secret", "App Secret", "secret", required=True),
        Field("domain", "Edition", "choice", choices=("feishu", "lark"), default="feishu"),
        Field("verbose", "Verbose", "bool"),
    )


@pytest.fixture()
def vault(settings: Settings) -> CredentialVault:
    return CredentialVault(settings.vault_file, settings.vault_key_file)


def test_codes_are_readable_and_long_enough():
    code = new_code()
    assert len(code) == CODE_LENGTH == 6
    assert set(code) <= set(CODE_ALPHABET)
    for confusable in "0O1I":
        assert confusable not in CODE_ALPHABET
    assert vault_name("feishu", "app_secret") == "CHANNEL_FEISHU_APP_SECRET"


def test_secrets_go_to_the_vault_and_never_come_back(settings: Settings, vault: CredentialVault):
    store = ChannelSettingsStore(settings.data_dir, vault)
    cfg = store.update(
        Demo,
        enabled=True,
        values={"app_id": " cli_1 ", "app_secret": "s3cret", "domain": "lark", "verbose": "yes"},
        allow_from=["u1", " ", "u2"],
        group_policy="open",
    )
    assert cfg.enabled and cfg.allow_from == ["u1", "u2"] and cfg.group_policy == "open"
    assert cfg.settings["app_id"] == "cli_1"
    assert cfg.settings["domain"] == "lark" and cfg.settings["verbose"] is True
    # the file holds a placeholder, the vault the value
    on_disk = json.loads((settings.data_dir / "channels" / "settings.json").read_text("utf-8"))
    assert on_disk["demo"]["settings"]["app_secret"] == "{{vault:CHANNEL_DEMO_APP_SECRET}}"
    assert "s3cret" not in (settings.data_dir / "channels" / "settings.json").read_text("utf-8")
    assert vault.get("CHANNEL_DEMO_APP_SECRET") == "s3cret"
    assert store.has_secret(cfg, "app_secret") is True
    assert store.resolved(cfg)["app_secret"] == "s3cret"
    # a field left out keeps its value; "" removes a secret
    cfg = store.update(Demo, values={"app_secret": ""})
    assert "app_secret" not in cfg.settings and vault.get("CHANNEL_DEMO_APP_SECRET") is None
    assert cfg.settings["app_id"] == "cli_1" and cfg.enabled
    assert store.has_secret(cfg, "app_secret") is False
    assert Demo.missing(cfg.settings) == ["app_secret"]
    with pytest.raises(ValueError):
        store.update(Demo, values={"domain": "slack"})
    with pytest.raises(ValueError):
        store.update(Demo, group_policy="everyone")


def test_config_toml_is_read_and_the_app_wins_per_field(
    settings: Settings, vault: CredentialVault, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
):
    monkeypatch.setenv("DEMO_SECRET", "from-env")
    config = tmp_path / "config.toml"
    config.write_text(
        "[channels.demo]\nenabled = true\napp_id = 'toml-id'\napp_secret = '${DEMO_SECRET}'\n"
        "allow_from = ['boss']\n",
        "utf-8",
    )
    store = ChannelSettingsStore(settings.data_dir, vault, str(config))
    cfg = store.config("demo")
    assert cfg.enabled and cfg.settings["app_id"] == "toml-id"
    assert cfg.settings["app_secret"] == "from-env" and cfg.allow_from == ["boss"]
    assert store.has_secret(cfg, "app_secret") is True
    store.update(Demo, values={"app_id": "app-id"})
    cfg = store.config("demo")
    assert cfg.settings["app_id"] == "app-id" and cfg.settings["app_secret"] == "from-env"
    # a file edited by someone else is re-read
    path = settings.data_dir / "channels" / "settings.json"
    data = json.loads(path.read_text("utf-8"))
    data["demo"]["enabled"] = False
    time.sleep(0.01)
    path.write_text(json.dumps(data), "utf-8")
    assert store.config("demo").enabled is False


def test_pairing_codes_approve_deny_and_expire(settings: Settings, monkeypatch: pytest.MonkeyPatch):
    pairing = PairingStore(settings.data_dir)
    code = pairing.request("demo", "u1", sender_name="Ann", chat_id="c1")
    assert len(code) == 6
    # the same person gets the same code while it is good
    assert pairing.request("demo", "u1") == code
    assert pairing.request("demo", "u2") != code
    assert [p["sender_id"] for p in pairing.pending()] == ["u1", "u2"]
    assert pairing.is_approved("demo", "u1") is False
    entry = pairing.approve(code.lower())
    assert entry and entry["channel"] == "demo" and entry["sender_id"] == "u1"
    assert entry["sender_name"] == "Ann" and entry["chat_id"] == "c1" and entry["deliver"] is False
    assert pairing.is_approved("demo", "u1") is True
    assert pairing.approve(code) is None  # used up
    assert pairing.deny("NOPE00") is None
    other = pairing.pending()[0]["code"]
    assert pairing.deny(other) and pairing.pending() == []
    # deliver here
    assert pairing.deliver_targets() == []
    assert pairing.set_deliver("demo", "u1", True)["deliver"] is True
    assert pairing.deliver_targets() == [("demo", "c1")]
    assert pairing.set_deliver("demo", "zz", True) is None
    pairing.touch("demo", "u1", sender_name="Ann B", chat_id="c9")
    assert pairing.entry("demo", "u1") == {
        "sender_name": "Ann B",
        "chat_id": "c9",
        "approved_at": entry["approved_at"],
        "deliver": True,
    }
    assert pairing.remove("demo", "u1") and not pairing.remove("demo", "u1")
    assert pairing.all_approved() == []
    # codes run out after ten minutes
    code = pairing.request("demo", "u3")
    now = time.time()
    monkeypatch.setattr(time, "time", lambda: now + 601)
    assert pairing.pending() == [] and pairing.approve(code) is None
