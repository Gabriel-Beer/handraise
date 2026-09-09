# /// script
# requires-python = ">=3.11"
# dependencies = ["mcp"]
# ///
"""MCP server: agents put tasks and questions on the screen overlay, then get the human's answers back.
Delivery: `wait_for_user` blocks until a batch is ready. If Claude was started with
`--channels server:handraise`, the server also rings the session (channel notification) the moment a batch
is ready, so the agent does not need to block; it then calls wait_for_user to collect and acknowledge.
Files under ~/.handraise:
  tasks/<prio>-<ns>.json  {title, session, ask, done, answer, send_now}  the overlay flips done/answer/send_now
  sessions/<sid>.json     {pid, cwd, name}                                the overlay checks pid to see if we're alive
"""
import asyncio
import json
import os
import time
from pathlib import Path

import anyio
from mcp.server.connection import Connection
from mcp.server.mcpserver import MCPServer
from mcp.server.stdio import stdio_server

ROOT = Path.home() / ".handraise"
TASKS, SESSIONS = ROOT / "tasks", ROOT / "sessions"
SID = os.environ.get("CLAUDE_CODE_SESSION_ID") or str(os.getppid())
RESUME = None
CONN: Connection | None = None  # the stdio connection, captured so the doorbell can notify outside a request
WAITING = 0                     # wait_for_user calls in progress; the doorbell stays quiet while one is pending
mcp = MCPServer("handraise")

_for_loop = Connection.for_loop


def _capture(*a, **k):
    global CONN
    CONN = _for_loop(*a, **k)
    return CONN


Connection.for_loop = staticmethod(_capture)


def resume_id() -> str:
    """`claude --resume` takes the transcript filename; the env id can be a later rotation that only
    appears inside the entries, so fall back to scanning the tail of recently written transcripts."""
    projects = Path.home() / ".claude" / "projects"
    if any(projects.glob(f"*/{SID}.jsonl")):
        return SID
    fresh = [f for f in projects.glob("*/*.jsonl") if f.stat().st_mtime > time.time() - 3600]
    for f in sorted(fresh, key=lambda f: f.stat().st_mtime, reverse=True):
        with f.open("rb") as fh:  # ponytail: last 2MB only, the rotated id lives in the newest entries
            fh.seek(max(0, f.stat().st_size - 2_000_000))
            if f'"session_id":"{SID}"'.encode() in fh.read():
                return f.stem
    return SID


def write(path: Path, data: dict):
    tmp = path.with_name("." + path.name)
    tmp.write_text(json.dumps(data))
    tmp.rename(path)  # atomic, so the overlay never reads a half-written file


def files():
    return sorted(f for f in TASKS.glob("*.json") if not f.name.startswith("."))


def mine():
    return [(f, t) for f in files() if (t := json.loads(f.read_text())).get("session") == SID]


def status():
    """(done, pending titles, ready): ready when nothing is pending, or the user pressed send-now on something."""
    tasks = mine()
    done = [(f, t) for f, t in tasks if t["done"]]
    pending = [t["title"] for _, t in tasks if not t["done"]]
    return done, pending, not tasks or not pending or any(t.get("send_now") for _, t in done)


def announce():
    global RESUME
    if RESUME is None:
        RESUME = resume_id()
    write(SESSIONS / f"{SID}.json", {"pid": os.getpid(), "cwd": os.getcwd(), "name": Path.cwd().name, "resume": RESUME})


for d in (TASKS, SESSIONS):
    d.mkdir(parents=True, exist_ok=True)
announce()


@mcp.tool()
def add_task(title: str, priority: int = 5, ask: bool = False) -> str:
    """Show a task on the user's screen overlay. priority 1 = most urgent, bigger = less urgent.
    ask=True when you need a text answer back ("check X and tell me what you see").
    Afterwards call wait_for_user to get the results."""
    name = f"{max(0, min(999, priority)):03d}-{time.time_ns()}.json"
    write(TASKS / name, {"title": title.strip(), "session": SID, "ask": ask,
                         "done": False, "answer": None, "send_now": False})
    return name


@mcp.tool()
def list_tasks() -> list[dict]:
    """Every task on screen, all agents, most urgent first."""
    return [{"id": f.name, "priority": int(f.name[:3]), **json.loads(f.read_text())} for f in files()]


@mcp.tool()
def remove_task(id: str) -> str:
    """Remove a task by id (from list_tasks)."""
    if Path(id).name != id:
        raise ValueError("bad id")
    (TASKS / id).unlink(missing_ok=True)
    return "ok"


@mcp.tool()
async def wait_for_user(timeout_seconds: int = 1500) -> dict:
    """Block until the user finished all your tasks (all_done=True) or pressed "send now" on one.
    Returns the finished tasks with their answers and clears them. On timeout you get what is still
    pending; just call again (the default stays under Claude Code's 30 min idle limit for stdio tools)."""
    global WAITING
    WAITING += 1
    try:
        deadline = time.monotonic() + timeout_seconds
        while True:
            done, pending, ready = status()
            if ready:
                for f, _ in done:
                    f.unlink(missing_ok=True)
                return {"all_done": not pending, "pending": pending,
                        "results": [{"title": t["title"], "answer": t.get("answer")} for _, t in done]}
            if time.monotonic() > deadline:
                return {"all_done": False, "timed_out": True, "pending": pending, "results": []}
            await asyncio.sleep(0.5)
    finally:
        WAITING -= 1


async def doorbell():
    """Ring the session once per ready batch, unless an agent is already blocked in wait_for_user."""
    rung = None
    while True:
        await asyncio.sleep(0.5)
        done, pending, ready = status()
        key = tuple(f.name for f, _ in done)
        if not (ready and done) or WAITING or key == rung or CONN is None or not CONN.initialized.is_set():
            continue
        lines = [f"- {t['title']}" + (f" -> {t['answer']}" if t.get("answer") else "") for _, t in done]
        head = "handraise: the user finished all your tasks." if not pending else "handraise: the user sent one answer early."
        content = "\n".join([head, *lines, "Call wait_for_user to collect and acknowledge them; that clears them from the overlay."])
        await CONN.outbound.notify("notifications/claude/channel", {"content": content, "meta": {"all_done": str(not pending).lower()}})
        rung = key


async def main():
    low = mcp._lowlevel_server
    init = low.create_initialization_options(experimental_capabilities={"claude/channel": {}})
    async with stdio_server() as (r, w):
        bell = asyncio.create_task(doorbell())
        try:
            await low.run(r, w, init)
        finally:
            bell.cancel()


if __name__ == "__main__":
    anyio.run(main)
