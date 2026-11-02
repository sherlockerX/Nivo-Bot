"""Holds (contract C1): the person takes the browser, the screen or the phone over for a
while; the agent's tools wait, then look again. The registry, the tools around it, the
operator loop, the HTTP routes and the hello state."""

from __future__ import annotations

import asyncio
import json
from collections.abc import Iterator
from pathlib import Path
from typing import Any

import pytest
from fastapi.testclient import TestClient

from nanomuse.agent.holds import Holds, took_over_note
from nanomuse.config import GUISettings, Settings
from nanomuse.llm.mock import MockLLM
from nanomuse.phone.link import PhoneLink
from nanomuse.phone.operator import (
    COMPUTER_USE_TOOL,
    MOBILE_USE_TOOL,
    PhoneOperator,
    to_computer_action,
    to_device_action,
)
from nanomuse.schema import RiskLevel
from nanomuse.server import create_app
from nanomuse.server.service import MuseService
from nanomuse.tools.phone import PhoneAct, PhoneScreen
from tests.test_browser import FakeBackend, tool_with
from tests.test_phone import (
    HOME_SCREEN,
    LOGIN_SCREEN,
    AutoApproveUI,
    FakePhone,
    labelled,
    make_sentinel,
)
from tests.test_server import events_of, wait_for


@pytest.fixture()
def server(settings: Settings) -> Iterator[tuple[TestClient, MuseService, MockLLM]]:
    settings.server.token = "secret-token"
    llm = MockLLM([])
    service = MuseService(settings, llm=llm)
    app = create_app(settings, service)
    with TestClient(app) as client:
        client.headers["Authorization"] = "Bearer secret-token"
        yield client, service, llm


def make_holds() -> tuple[Holds, list[dict[str, Any]]]:
    events: list[dict[str, Any]] = []
    return Holds(emit=events.append, thread_of=lambda: "t1"), events


# ----------------------------------------------------------------------------- the registry
async def test_registry_opens_reuses_and_closes_holds():
    holds, events = make_holds()
    assert holds.view() == [] and not holds.is_held("t1", "browser")

    hold = holds.open("t1", "browser", by="user")
    assert hold.open and hold.by == "user" and hold.id.startswith("h_")
    assert events[-1]["type"] == "hold" and events[-1]["status"] == "on"
    assert events[-1]["tool"] == "browser" and isinstance(events[-1]["ts"], float)
    assert holds.is_held("t1", "browser") and not holds.is_held("t1", "phone")
    assert not holds.is_held("t2", "browser")  # another chat is not held

    # a second take-over of the same chat and tool is the same hold, not a second card
    again = holds.open("t1", "browser", by="agent", reason="sign in")
    assert again is hold and hold.reason == "sign in" and len(events) == 2
    assert [e["status"] for e in holds.view()] == ["on"]

    done = holds.done(hold.id)
    assert done is hold and not hold.open and hold.done_ts is not None
    assert events[-1]["status"] == "off" and events[-1]["id"] == hold.id
    assert holds.view() == []
    # done twice changes nothing; an unknown id is None
    assert holds.done(hold.id) is hold and len(events) == 3
    assert holds.done("h_nope") is None

    with pytest.raises(ValueError):
        holds.open("t1", "toaster")
    with pytest.raises(ValueError):
        holds.open("t1", "phone", by="cat")

    # release by chat and tool, and clearing a chat
    h2 = holds.open("t1", "phone")
    assert holds.release("t1", "phone") is h2 and holds.release("t1", "phone") is None
    h3 = holds.open("t2", "computer")
    holds.clear_thread("t2")
    assert not h3.open and holds.get(h3.id) is None


async def test_wait_blocks_while_a_hold_is_on_and_returns_whether_it_waited():
    holds, _ = make_holds()
    assert await holds.wait("t1", "browser") is False  # the way is clear

    hold = holds.open("t1", "browser")
    waiter = asyncio.ensure_future(holds.wait("t1", "browser"))
    await asyncio.sleep(0.05)
    assert not waiter.done()
    holds.done(hold.id)
    assert await asyncio.wait_for(waiter, 1) is True

    # a hold that is re-opened right after Done keeps the waiter waiting
    first = holds.open("t1", "phone")
    waiter = asyncio.ensure_future(holds.wait("t1", "phone"))
    await asyncio.sleep(0.01)
    holds.done(first.id)
    second = holds.open("t1", "phone")
    await asyncio.sleep(0.05)
    assert not waiter.done()
    holds.done(second.id)
    assert await asyncio.wait_for(waiter, 1) is True

    # with a timeout the wait gives up, hold or no hold
    holds.open("t1", "computer")
    assert await holds.wait("t1", "computer", timeout=0.05) is True


async def test_hand_over_waits_for_done_or_times_out():
    holds, events = make_holds()

    async def finish_soon() -> None:
        await asyncio.sleep(0.05)
        [hold] = holds.active("t1")
        assert hold.by == "agent" and hold.reason == "sign in to Gmail"
        holds.done(hold.id)

    asyncio.ensure_future(finish_soon())
    assert await holds.hand_over("t1", "browser", "sign in to Gmail", timeout=2) is True
    assert events[-1]["status"] == "off" and "timed_out" not in events[-1]

    assert await holds.hand_over("t1", "browser", "enter the code", timeout=0.05) is False
    assert events[-1]["status"] == "off" and events[-1]["timed_out"] is True
    assert holds.view() == []  # the timed-out hold is off, so the next action does not wait

    assert "has finished" in took_over_note("browser")
    assert "did not come back within 10 minutes" in took_over_note("phone", finished=False)


# ----------------------------------------------------------------------------- the tools
async def test_browser_tool_waits_for_the_user_and_hands_over(tmp_path: Path):
    tool, frames = tool_with(FakeBackend(), tmp_path)
    holds, events = make_holds()
    tool.holds = holds
    tool.hand_over_timeout = 0.1

    await tool.execute(action="navigate", url="https://example.com")
    hold = holds.open("t1", "browser")
    task = asyncio.ensure_future(tool.execute(action="extract"))
    await asyncio.sleep(0.05)
    assert not task.done()  # the action waits, it does not fail
    holds.done(hold.id)
    result = await asyncio.wait_for(task, 1)
    assert result.ok and result.output.startswith("Note: the user took over the browser")

    # the agent's own hand-over: a hold by the agent with the reason, Done brings the page back
    async def user_signs_in() -> None:
        await asyncio.sleep(0.03)
        [h] = holds.active("t1")
        assert h.by == "agent" and h.reason == "sign in to the shop"
        holds.done(h.id)

    asyncio.ensure_future(user_signs_in())
    result = await tool.execute(action="hand_over", reason="sign in to the shop")
    assert result.ok and "has finished" in result.output and "URL: " in result.output
    assert frames[-2].action.startswith("Your turn: sign in to the shop")
    assert frames[-1].action == "You handed the page back"

    # nobody comes: the tool says so and the hold is off
    result = await tool.execute(action="hand_over", reason="enter the code")
    assert result.ok and "did not come back" in result.output and holds.view() == []
    assert (await tool.execute(action="hand_over")).error  # a reason is required
    assert tool.assess({"action": "hand_over", "reason": "x"}).risk == RiskLevel.SAFE
    assert "hand_over" in tool.parameters["properties"]["action"]["enum"]

    # take_over / handed_back are user actions the viewer sends
    await tool.user_action("take_over", "t1")
    assert frames[-1].action == "You have the page" and frames[-1].by_user


async def test_phone_tools_wait_and_hand_over(settings: Settings):
    link = PhoneLink(shots_dir=settings.agent.workspace / "screenshots")
    FakePhone(link, [HOME_SCREEN])
    holds, _ = make_holds()
    screen_tool = PhoneScreen(link=link, holds=holds)
    act = PhoneAct(link=link, gui=GUISettings(), holds=holds, hand_over_timeout=0.05)

    hold = holds.open("t1", "phone", reason="my turn")
    task = asyncio.ensure_future(screen_tool.execute())
    await asyncio.sleep(0.03)
    assert not task.done()
    holds.done(hold.id)
    result = await asyncio.wait_for(task, 1)
    assert result.ok and result.output.startswith("Note: the user took over the phone")

    result = await act.execute(action="hand_over", reason="enter the SMS code")
    assert result.ok and "did not come back" in result.output and "Home" in result.output
    assert (await act.execute(action="hand_over")).error
    assert act.assess({"action": "hand_over", "reason": "r"}).risk == RiskLevel.SAFE


# ----------------------------------------------------------------------------- the operator
def test_dialects_offer_hand_over_and_the_loop_treats_it_as_a_pause():
    for tool in (MOBILE_USE_TOOL, COMPUTER_USE_TOOL):
        props = tool["function"]["parameters"]["properties"]
        assert "hand_over" in props["action"]["enum"]
        assert "hand_over" in props["action"]["description"]
    from nanomuse.phone.operator import Step
    from nanomuse.phone.screen import Screen

    step = Step("t", "a", "mobile_use", {"action": "hand_over", "text": "sign in"})
    screen = Screen(width=100, height=100)
    assert to_device_action(step, screen) is None
    step.name = "computer_use"
    assert to_computer_action(step, screen) is None


async def test_operator_hands_the_phone_over_and_continues(settings: Settings):
    link = PhoneLink(shots_dir=settings.agent.workspace / "screenshots")
    phone = FakePhone(link, [LOGIN_SCREEN, LOGIN_SCREEN, HOME_SCREEN, HOME_SCREEN])
    ui = AutoApproveUI()
    llm = MockLLM(
        [
            labelled("Hand over for the sign-in", "hand_over", text="请登录微信"),
            labelled("Tap 登录", "click", coordinate=[500, 500]),
            labelled("Report", "answer", text="signed in"),
        ]
    )
    holds, events = make_holds()
    gui = GUISettings(max_steps=6)
    act = PhoneAct(link=link, gui=gui, holds=holds)
    operator = PhoneOperator(
        link,
        gui,
        make_sentinel(settings, ui),
        act,
        ui,
        make_llm=lambda: llm,
        traces_dir=settings.data_dir / "phone-traces",
        holds=holds,
    )
    operator.hand_over_timeout = 2

    async def user_logs_in() -> None:
        for _ in range(50):
            await asyncio.sleep(0.01)
            if holds.active("t1"):
                break
        [hold] = holds.active("t1")
        assert hold.by == "agent" and hold.reason == "请登录微信" and hold.tool == "phone"
        holds.done(hold.id)

    asyncio.ensure_future(user_logs_in())
    outcome = await operator.run("sign in to WeChat")
    assert outcome.status == "done" and outcome.message == "signed in"
    assert outcome.actions[0] == "hand over: 请登录微信"
    # the model was told, in the progress, that the user did their part
    third = llm.calls[1]["messages"][1].content
    assert "the user took over the phone for a while and has finished" in third
    assert phone.acts[-1]["action"] == "tap"
    assert [e["status"] for e in events] == ["on", "off"]
    # the system prompt sends secrets to hand_over, not ask_user
    assert "action=hand_over before that step" in operator.system_prompt()


async def test_operator_never_types_into_a_password_field(settings: Settings):
    link = PhoneLink(shots_dir=settings.agent.workspace / "screenshots")
    focused_login = json.loads(json.dumps(LOGIN_SCREEN))
    focused_login["nodes"][1]["focused"] = True
    phone = FakePhone(link, [focused_login, focused_login, HOME_SCREEN])
    ui = AutoApproveUI()
    llm = MockLLM(
        [
            labelled("Type the password", "type", text="hunter2"),
            labelled("Report", "answer", text="done"),
        ]
    )
    holds, events = make_holds()
    gui = GUISettings(max_steps=5)
    act = PhoneAct(link=link, gui=gui, holds=holds)
    operator = PhoneOperator(
        link, gui, make_sentinel(settings, ui), act, ui, make_llm=lambda: llm, holds=holds
    )
    operator.hand_over_timeout = 0.05
    outcome = await operator.run("log in")
    assert outcome.status == "done"
    assert phone.acts == []  # nothing was typed
    assert events[0]["by"] == "agent" and "password or code field" in events[0]["reason"]
    assert "did not come back" in llm.calls[1]["messages"][1].content


async def test_operator_without_an_app_falls_back_to_asking(settings: Settings):
    link = PhoneLink(shots_dir=settings.agent.workspace / "screenshots")
    FakePhone(link, [HOME_SCREEN])
    ui = AutoApproveUI()
    llm = MockLLM([labelled("Hand over", "hand_over", text="please sign in")])
    gui = GUISettings(max_steps=3)
    act = PhoneAct(link=link, gui=gui)
    operator = PhoneOperator(link, gui, make_sentinel(settings, ui), act, ui, make_llm=lambda: llm)
    outcome = await operator.run("sign in")
    assert outcome.status == "ask" and outcome.message == "please sign in"


async def test_operator_pauses_while_the_user_has_the_phone(settings: Settings):
    link = PhoneLink(shots_dir=settings.agent.workspace / "screenshots")
    FakePhone(link, [HOME_SCREEN])
    ui = AutoApproveUI()
    llm = MockLLM([labelled("Report", "answer", text="ok")])
    holds, _ = make_holds()
    gui = GUISettings(max_steps=3)
    act = PhoneAct(link=link, gui=gui, holds=holds)
    operator = PhoneOperator(
        link, gui, make_sentinel(settings, ui), act, ui, make_llm=lambda: llm, holds=holds
    )
    hold = holds.open("t1", "phone")
    run = asyncio.ensure_future(operator.run("look"))
    await asyncio.sleep(0.05)
    assert not run.done() and llm.calls == []
    holds.done(hold.id)
    outcome = await asyncio.wait_for(run, 2)
    assert outcome.status == "done"
    assert "took over the phone" in llm.calls[0]["messages"][1].content


# ----------------------------------------------------------------------------- the server
def test_holds_api_and_hello_state(server):
    client, svc, _ = server
    hello = client.get("/api/state").json()
    assert hello["holds"] == []

    r = client.post("/api/holds", json={"thread": "main", "tool": "browser"})
    assert r.status_code == 200
    hold = r.json()
    assert hold["type"] == "hold" and hold["status"] == "on" and hold["by"] == "user"
    assert client.get("/api/state").json()["holds"] == [hold]
    assert client.get("/api/holds").json() == [hold]
    # it is a card in the chat's timeline
    card = wait_for(lambda: events_of(client, "main", "hold"))[0]
    assert card["id"] == hold["id"] and card["status"] == "on"

    # the same take-over again is the same hold
    again = client.post("/api/holds", json={"thread": "main", "tool": "browser", "reason": "me"})
    assert again.json()["id"] == hold["id"] and again.json()["reason"] == "me"

    r = client.post(f"/api/holds/{hold['id']}/done")
    assert r.status_code == 200 and r.json()["status"] == "off"
    assert client.get("/api/state").json()["holds"] == []
    card = wait_for(lambda: [e for e in events_of(client, "main", "hold") if e["status"] == "off"])[
        0
    ]
    assert card["id"] == hold["id"] and card["reason"] == "me"

    assert client.post("/api/holds/h_nope/done").status_code == 404
    assert client.post("/api/holds", json={"thread": "nope", "tool": "phone"}).status_code == 404
    assert client.post("/api/holds", json={"thread": "main", "tool": "cat"}).status_code == 422

    # the browser viewer's own words: take_over puts a hold on, handed_back takes it off,
    # with or without an open page
    r = client.post("/api/browser/main/control", json={"action": "take_over"})
    assert r.status_code == 200 and r.json()["hold"]["status"] == "on"
    assert svc.app.holds.is_held("main", "browser")
    r = client.post("/api/browser/main/control", json={"action": "handed_back"})
    assert r.status_code == 200 and r.json()["hold"]["status"] == "off"
    assert not svc.app.holds.is_held("main", "browser")
