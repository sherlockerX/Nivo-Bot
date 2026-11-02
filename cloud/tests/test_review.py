"""The review sign-in: an app store's reviewer signs in with a fixed code and gets nothing sent."""

from __future__ import annotations

from test_accounts import make
from test_cloud import sign_up

REVIEW = "review@example.com"
OTHER = "someone@example.com"


async def request(client, identifier: str):
    return await client.post("/v1/auth/code", json={"identifier": identifier})


async def verify(client, identifier: str, code: str):
    return await client.post("/v1/auth/verify", json={"identifier": identifier, "code": code, "device": "iphone"})


def test_off_unless_both_values_are_set():
    for overrides in (
        {},
        {"review_addresses": REVIEW},
        {"review_code": "246810"},
        {"review_addresses": REVIEW, "review_code": "12345"},  # five digits
        {"review_addresses": REVIEW, "review_code": "abcdef"},
        {"review_addresses": "13800138000", "review_code": "246810"},  # a number, not an address
    ):
        *_, cloud, _settings = make(**overrides)
        assert cloud.review_hashes == frozenset(), overrides


async def test_off_the_address_is_an_ordinary_one():
    app, client, sender, up, cloud, settings = make(review_addresses=REVIEW)  # no REVIEW_CODE
    r = await request(client, REVIEW)
    assert r.status_code == 204
    assert len(sender.sent) == 1 and sender.sent[-1][0].value == REVIEW  # a real code went out
    r = await verify(client, REVIEW, "246810")
    assert r.status_code == 400 and r.json()["error"]["code"] == "code_wrong"


async def test_review_address_signs_in_with_the_fixed_code_and_nothing_is_sent():
    app, client, sender, up, cloud, settings = make(review_addresses=f" {REVIEW}, bad entry ", review_code="246810")
    assert len(cloud.review_hashes) == 1

    # Nothing before a request: the same lifetime rules as a real code.
    r = await verify(client, REVIEW, "246810")
    assert r.status_code == 400 and r.json()["error"]["code"] == "code_expired"

    r = await request(client, REVIEW)
    assert r.status_code == 204
    assert sender.sent == []  # nothing went anywhere

    # Only the fixed code opens it.
    r = await verify(client, REVIEW, "000000")
    assert r.status_code == 400 and r.json()["error"]["code"] == "code_wrong"
    r = await verify(client, REVIEW, "246810")
    assert r.status_code == 200, r.text
    me = r.json()
    assert me["created"] is True
    account_id = me["account"]["id"]
    assert me["account"].get("member") is not True  # an ordinary account, the usual allowance
    assert me["spend"]["grant"] == 25 and me["spend"]["unlimited"] is False

    # A second sign-in is the same account, not a second one.
    await request(client, REVIEW)
    r = await verify(client, REVIEW, "246810")
    assert r.status_code == 200 and r.json()["created"] is False and r.json()["account"]["id"] == account_id

    # Everyone else is untouched: a real code is sent and the fixed code means nothing.
    other = await sign_up(client, sender, OTHER, "pixel")
    assert len(sender.sent) == 1 and sender.sent[-1][0].value == OTHER
    await request(client, OTHER)
    r = await verify(client, OTHER, "246810")
    assert r.status_code == 400 and r.json()["error"]["code"] == "code_wrong"

    # The operator's page tags the account `review` and leaves it out of the sign-up counts.
    rows = (await client.get("/v1/admin/accounts", headers={"X-Admin-Token": "admin"})).json()["accounts"]
    flags = {a["id"]: a["review"] for a in rows}
    assert flags == {account_id: True, other["account"]["id"]: False}
    one = (await client.get(f"/v1/admin/accounts/{account_id}", headers={"X-Admin-Token": "admin"})).json()["account"]
    assert one["review"] is True and one["member"] is False
    overview = (await client.get("/v1/admin/overview", headers={"X-Admin-Token": "admin"})).json()
    assert overview["today"]["new_accounts"] == 1 and overview["accounts"]["total"] == 2
    series = (await client.get("/v1/admin/series?days=3", headers={"X-Admin-Token": "admin"})).json()
    assert sum(d["new_accounts"] for d in series["days"]) == 1

    # Rate limits apply to the reviewer like anyone: the code attempts run out.
    await request(client, REVIEW)
    for _ in range(settings.code_max_attempts):
        r = await verify(client, REVIEW, "111111")
        assert r.status_code == 400 and r.json()["error"]["code"] == "code_wrong"
    r = await verify(client, REVIEW, "246810")
    assert r.status_code == 400 and r.json()["error"]["code"] == "code_expired"


async def test_review_address_may_sign_in_on_a_private_relay():
    app, client, sender, up, cloud, settings = make(signup_open=False, review_addresses=REVIEW, review_code="246810")
    r = await request(client, OTHER)
    assert r.status_code == 403 and r.json()["error"]["code"] == "not_invited"
    r = await request(client, REVIEW)
    assert r.status_code == 204 and sender.sent == []
    r = await verify(client, REVIEW, "246810")
    assert r.status_code == 200, r.text
