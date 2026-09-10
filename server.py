# /// script
# requires-python = ">=3.11"
# dependencies = ["mcp"]
# ///
"""MCP server: agents put tasks and questions on the screen overlay, then get the human's answers back.
Delivery: the moment a batch is ready the server posts a message into the Claude Code session that
spawned it, over the session's inbox socket (cross-session messaging, on by default), and the agent
calls wait_for_user to collect and acknowledge. wait_for_user also blocks when called early.
Files under ~/.handraise:
  tasks/<prio>-<ns>.json  {title, session, ask, done, answer, send_now}  the overlay flips done/answer/send_now
  sessions/<sid>.json     {pid, cwd, name, resume}                       the overlay checks pid to see if we're alive
"""
import asyncio
import json
import os
import socket
import time
from pathlib import Path

import anyio
from mcp.server.mcpserver import MCPServer
from mcp.server.stdio import stdio_server

ROOT = Path.home() / ".handraise"
TASKS, SESSIONS = ROOT / "tasks", ROOT / "sessions"
SID = os.environ.get("CLAUDE_CODE_SESSION_ID") or str(os.getppid())
INBOX, TOKEN = os.environ.get("CLAUDE_CODE_MESSAGING_SOCKET"), os.environ.get("CLAUDE_CODE_MESSAGING_TOKEN", "")
RESUME = None
WAITING = 0  # wait_for_user calls in progress; the doorbell stays quiet while one is pending
mcp = MCPServer("handraise", instructions="handraise shows your tasks and questions to the user on a screen overlay. " + (
    "When a batch is ready you receive a message from handraise listing the finished tasks and answers; call "
    "wait_for_user then, it returns immediately with the results and clears them from the screen. You do not need "
    "to block for them." if INBOX else
    "This session has no inbox to notify you, so call wait_for_user right after adding your tasks; it blocks until "
    "the user is done."))


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


def post(content: str):
    """Push a message into the session that spawned us, over its inbox socket (Claude Code cross-session
    messaging). Claude Code sees we are its own child, so it is delivered without an approval dialog."""
    with socket.socket(socket.AF_UNIX) as s:
        s.settimeout(5)
        s.connect(INBOX)
        s.sendall("".join(json.dumps(m) + "\n" for m in (
            {"type": "auth", "token": TOKEN},
            {"type": "user", "from": "handraise", "message": {"role": "user", "content": content}})).encode())


async def doorbell():
    """Ring the session once per ready batch, unless an agent is already blocked in wait_for_user."""
    rung = None
    while INBOX:
        await asyncio.sleep(0.5)
        done, pending, ready = status()
        key = tuple(f.name for f, _ in done)
        if not (ready and done) or WAITING or key == rung:
            continue
        lines = [f"- {t['title']}" + (f" -> {t['answer']}" if t.get("answer") else "") for _, t in done]
        head = "handraise: the user finished all your tasks." if not pending else "handraise: the user sent one answer early."
        try:
            post("\n".join([head, *lines, "Call wait_for_user to collect and acknowledge them; that clears them from the overlay."]))
        except OSError:
            continue  # inbox not up yet or the session is going away; try again next tick
        rung = key


async def main():
    low = mcp._lowlevel_server
    async with stdio_server() as (r, w):
        bell = asyncio.create_task(doorbell())
        try:
            await low.run(r, w, low.create_initialization_options())
        finally:
            bell.cancel()


if __name__ == "__main__":
    anyio.run(main)
