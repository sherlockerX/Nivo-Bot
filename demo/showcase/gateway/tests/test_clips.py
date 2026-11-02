"""The chosen face animated: the video API's four calls, stood in for and counted."""

from __future__ import annotations

import base64
import json
from dataclasses import replace

import httpx

from showcase_gateway.app import create_app
from showcase_gateway.clips import is_clip_path
from showcase_gateway.sessions import SessionManager

from .conftest import body


async def client_for(app) -> httpx.AsyncClient:
    transport = httpx.ASGITransport(app=app)
    return httpx.AsyncClient(transport=transport, base_url="http://localhost:8000")


def test_the_video_api_paths():
    assert is_clip_path("api/v1/uploads") and is_clip_path("/api/v1/uploads/put")
    assert is_clip_path("api/v1/services/aigc/video-generation/video-synthesis")
    assert is_clip_path("api/v1/tasks/abc") and is_clip_path("api/v1/clips/abc")
    assert not is_clip_path("chat/completions") and not is_clip_path("images/generations")


async def _frame(c: httpx.AsyncClient, base: str, auth: dict, png: bytes = b"PNGFRAME") -> str:
    """The first two calls of a clip, as the studio makes them: the policy, then the upload.
    Returns the frame's key."""
    r = await c.get(f"{base}/api/v1/uploads", params={"action": "getPolicy"}, headers=auth)
    assert r.status_code == 200, r.text
    policy = body(r)["data"]
    assert policy["upload_host"] == f"http://10.0.0.1:8000{base}/api/v1/uploads/put"
    key = f"{policy['upload_dir']}/first-frame.png"
    r = await c.post(
        policy["upload_host"].replace("http://10.0.0.1:8000", ""),
        data={
            "OSSAccessKeyId": policy["oss_access_key_id"],
            "Signature": policy["signature"],
            "policy": policy["policy"],
            "x-oss-object-acl": policy["x_oss_object_acl"],
            "x-oss-forbid-overwrite": policy["x_oss_forbid_overwrite"],
            "key": key,
        },
        files={"file": ("first-frame.png", png, "image/png")},
    )
    assert r.status_code == 204, r.text
    return key


async def test_a_face_is_animated_through_the_gateway_and_counted(world):
    settings, runner, upstream, clock, manager, app = world
    async with app.router.lifespan_context(app):
        c = await client_for(app)
        info = body(await c.get("/api/demo/info"))
        assert info["video_model"] == "wan2.2-i2v-flash" and info["quota"]["clips"] == 2
        sess = body(await c.post("/api/demo/session", json={}))
        env = runner.running[f"nm-{sess['id']}"]
        base = f"/llm/{sess['id']}/main"
        # the container is told the video model and that the video API is at its own model
        # address — where the gateway stands in for Model Studio's storage
        assert env["NANOMUSE_LLM_VIDEO_MODEL"] == "wan2.2-i2v-flash"
        assert env["NANOMUSE_LLM_VIDEO_BASE_URL"] == f"http://10.0.0.1:8000{base}"
        auth = {"authorization": f"Bearer {env['NANOMUSE_LLM_API_KEY']}"}

        # the policy wants the session's key
        r = await c.get(
            f"{base}/api/v1/uploads",
            params={"action": "getPolicy"},
            headers={"authorization": "Bearer nope"},
        )
        assert r.status_code == 401
        key = await _frame(c, base, auth)

        # the task: the frame goes up inline, on the showcase's key and model
        synthesis = f"{base}/api/v1/services/aigc/video-generation/video-synthesis"
        task_body = {
            "model": "whatever-i2v",
            "input": {"prompt": "the face blinks", "img_url": f"oss://{key}"},
            "parameters": {"watermark": True, "resolution": "480P", "duration": 30, "seed": 1},
        }
        r = await c.post(synthesis, json=task_body, headers=auth)
        assert r.status_code == 200, r.text
        assert body(r)["output"]["task_id"] == "task-1"
        sent = upstream.animated[-1]
        assert sent.headers["authorization"] == "Bearer sk-draw"
        assert sent.headers["x-dashscope-async"] == "enable"
        assert str(sent.url) == (
            "https://draw.example/api/v1/services/aigc/video-generation/video-synthesis"
        )
        payload = json.loads(sent.content)
        assert payload["model"] == "wan2.2-i2v-flash"
        assert payload["input"]["prompt"] == "the face blinks"
        assert (
            payload["input"]["img_url"]
            == "data:image/png;base64," + base64.b64encode(b"PNGFRAME").decode()
        )
        # the session's say on the parameters is bounded: no watermark off, five seconds at most
        assert payload["parameters"] == {"watermark": False, "resolution": "480P", "duration": 5}
        assert manager.sessions[sess["id"]].clips == 1 and manager.day_clips == 1

        # polling: running, then done — with the clip's address rewritten to the gateway
        r = await c.get(f"{base}/api/v1/tasks/task-1", headers=auth)
        assert r.status_code == 200 and body(r)["output"]["task_status"] == "RUNNING"
        r = await c.get(f"{base}/api/v1/tasks/task-1", headers=auth)
        out = body(r)["output"]
        assert out["task_status"] == "SUCCEEDED"
        assert out["video_url"] == f"http://10.0.0.1:8000{base}/api/v1/clips/task-1"
        # the file, fetched the way the studio does it (no header), from the provider's storage
        r = await c.get(f"{base}/api/v1/clips/task-1")
        assert r.status_code == 200 and r.content == b"MP4BYTES"
        assert r.headers["content-type"].startswith("video/mp4")
        assert str(upstream.calls[-1].url) == "https://oss.draw.example/v/task-1.mp4"

        # a second clip reuses nothing: a fresh policy and frame each time
        key2 = await _frame(c, base, auth, b"PNG2")
        r = await c.post(
            synthesis,
            json={**task_body, "input": {"prompt": "it nods", "img_url": f"oss://{key2}"}},
            headers=auth,
        )
        assert r.status_code == 200
        # the third is over the session's share
        key3 = await _frame(c, base, auth)
        r = await c.post(
            synthesis,
            json={**task_body, "input": {"prompt": "it waves", "img_url": f"oss://{key3}"}},
            headers=auth,
        )
        assert r.status_code == 429 and body(r)["code"] == "clip_budget"
        assert manager.sessions[sess["id"]].clips == 2
        public = body(
            await c.get(
                f"/api/demo/session/{sess['id']}",
                headers={"authorization": f"Bearer {sess['token']}"},
            )
        )
        assert public["quota"]["clips"] == 2 and public["quota"]["clips_used"] == 2


async def test_the_frame_must_be_the_sessions_own(world):
    settings, runner, upstream, clock, manager, app = world
    async with app.router.lifespan_context(app):
        c = await client_for(app)
        a = body(await c.post("/api/demo/session", json={}))
        b = body(await c.post("/api/demo/session", json={}, headers={"x-forwarded-for": "9.9.9.9"}))
        base_a, base_b = f"/llm/{a['id']}/main", f"/llm/{b['id']}/main"
        key_a = runner.running["nm-" + a["id"]]["NANOMUSE_LLM_API_KEY"]
        key_b = runner.running["nm-" + b["id"]]["NANOMUSE_LLM_API_KEY"]
        auth_a = {"authorization": f"Bearer {key_a}"}
        auth_b = {"authorization": f"Bearer {key_b}"}
        synthesis = "/api/v1/services/aigc/video-generation/video-synthesis"

        # an upload without a policy of ours
        r = await c.post(
            f"{base_a}/api/v1/uploads/put",
            data={"policy": "forged", "key": f"{a['id']}/x/first-frame.png"},
            files={"file": ("f.png", b"PNG", "image/png")},
        )
        assert r.status_code == 403
        # a's frame cannot be b's first frame, and a task without a frame starts nothing
        key = await _frame(c, base_a, auth_a)
        r = await c.post(
            f"{base_b}{synthesis}",
            json={"input": {"prompt": "p", "img_url": f"oss://{key}"}},
            headers=auth_b,
        )
        assert r.status_code == 400 and body(r)["code"] == "no_frame"
        assert not upstream.animated
        # a frame expires
        await c.post(
            f"{base_a}{synthesis}",
            json={"input": {"prompt": "p", "img_url": f"oss://{key}"}},
            headers=auth_a,
        )
        assert len(upstream.animated) == 1
        # b cannot poll or fetch a's task
        r = await c.get(f"{base_b}/api/v1/tasks/task-1", headers=auth_b)
        assert r.status_code == 404
        r = await c.get(f"{base_b}/api/v1/clips/task-1")
        assert r.status_code == 404
        # a busy provider is passed on as such (the studio itself waits and asks again)
        upstream.animate_busy = 1
        key2 = await _frame(c, base_a, auth_a)
        r = await c.post(
            f"{base_a}{synthesis}",
            json={"input": {"prompt": "p", "img_url": f"oss://{key2}"}},
            headers=auth_a,
        )
        assert r.status_code == 429 and body(r)["code"] == "provider_busy"
        assert manager.sessions[a["id"]].clips == 1
        # the frame is still there for the retry; after ten minutes it is gone
        clock.now += 11 * 60
        r = await c.post(
            f"{base_a}{synthesis}",
            json={"input": {"prompt": "p", "img_url": f"oss://{key2}"}},
            headers=auth_a,
        )
        assert r.status_code == 400 and body(r)["code"] == "no_frame"


async def test_no_video_model_means_stills_only(world):
    settings, runner, upstream, clock, manager, app = world
    settings = replace(settings, video_model="")
    manager = SessionManager(settings, runner, http=manager.http, clock=clock)
    manager.resolve = lambda host, port: ["93.184.216.34"]
    app = create_app(settings, manager, client=manager.http)
    async with app.router.lifespan_context(app):
        c = await client_for(app)
        info = body(await c.get("/api/demo/info"))
        assert info["image_model"] == "qwen-image-3.0"
        assert info["video_model"] is None and info["quota"]["clips"] == 0
        sess = body(await c.post("/api/demo/session", json={}))
        env = runner.running[f"nm-{sess['id']}"]
        assert "NANOMUSE_LLM_VIDEO_BASE_URL" not in env and "NANOMUSE_LLM_VIDEO_MODEL" not in env
        auth = {"authorization": f"Bearer {env['NANOMUSE_LLM_API_KEY']}"}
        r = await c.get(
            f"/llm/{sess['id']}/main/api/v1/uploads", params={"action": "getPolicy"}, headers=auth
        )
        assert r.status_code == 404 and body(r)["code"] == "no_video_model"
