# /// script
# requires-python = ">=3.11"
# dependencies = ["mcp"]
# ///
"""uv run check.py : drives the real server over stdio, plays the overlay by editing the task files."""
import asyncio
import json
import os
from pathlib import Path

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

SID = f"check-{os.getpid()}"
TASKS = Path.home() / ".handraise" / "tasks"


def mark(name, answer=None, send_now=False):  # what the overlay does on ✓ / send-now
    f = TASKS / name
    f.write_text(json.dumps({**json.loads(f.read_text()), "done": True, "answer": answer, "send_now": send_now}))


async def main():
    params = StdioServerParameters(command="uv", args=["run", "server.py"], env={**os.environ, "CLAUDE_CODE_SESSION_ID": SID})
    async with stdio_client(params) as (r, w), ClientSession(r, w) as s:
        await s.initialize()
        call = lambda name, **a: s.call_tool(name, a)
        def sc(res):  # list tools come back as {"result": [...]}, dict tools only as text
            s = res.structured_content
            return json.loads(res.content[0].text) if s is None else s.get("result", s)

        plain = (await call("add_task", title="  restart the router ", priority=1)).content[0].text
        sess = json.loads((TASKS.parent / "sessions" / f"{SID}.json").read_text())
        assert sess["cwd"] == os.getcwd() and sess["resume"] == SID and os.kill(sess["pid"], 0) is None, sess
        q = (await call("add_task", title="what does the LED show?", priority=2, ask=True)).content[0].text
        lo = (await call("add_task", title="later", priority=5000)).content[0].text
        assert lo.startswith("999-"), lo
        ids = [t["id"] for t in sc(await call("list_tasks"))]
        assert ids.index(plain) < ids.index(q) < ids.index(lo), ids

        r = sc(await call("wait_for_user", timeout_seconds=1))
        assert r["timed_out"] and {"restart the router", "what does the LED show?"} <= set(r["pending"]), r

        mark(q, answer="green", send_now=True)
        r = sc(await call("wait_for_user", timeout_seconds=5))
        assert r["results"] == [{"title": "what does the LED show?", "answer": "green"}] and not r["all_done"], r
        assert not (TASKS / q).exists()

        mark(plain), mark(lo)
        r = sc(await call("wait_for_user", timeout_seconds=5))
        assert r["all_done"] and {x["title"] for x in r["results"]} == {"restart the router", "later"}, r
        assert not any(t["id"] in (plain, lo) for t in sc(await call("list_tasks")))

        assert (await call("remove_task", id="../x")).is_error
        (TASKS.parent / "sessions" / f"{SID}.json").unlink()
        print("ok")


asyncio.run(main())
