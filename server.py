# /// script
# requires-python = ">=3.11"
# dependencies = ["mcp"]
# ///
"""MCP server: agents put tasks and questions on the screen overlay, then wait for the human.
Files under ~/.handraise:
  tasks/<prio>-<ns>.json  {title, session, ask, done, answer, send_now}  the overlay flips done/answer/send_now
  sessions/<sid>.json     {pid, cwd, name}                                the overlay checks pid to see if we're alive
"""
import asyncio
import json
import os
import time
from pathlib import Path

from mcp.server.mcpserver import MCPServer

ROOT = Path.home() / ".handraise"
TASKS, SESSIONS = ROOT / "tasks", ROOT / "sessions"
SID = os.environ.get("CLAUDE_CODE_SESSION_ID") or str(os.getppid())
RESUME = None
mcp = MCPServer("handraise")


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
    deadline = time.monotonic() + timeout_seconds
    while True:
        tasks = mine()
        done = [(f, t) for f, t in tasks if t["done"]]
        pending = [t["title"] for _, t in tasks if not t["done"]]
        if not tasks or not pending or any(t.get("send_now") for _, t in done):
            for f, _ in done:
                f.unlink(missing_ok=True)
            return {"all_done": not pending, "pending": pending,
                    "results": [{"title": t["title"], "answer": t.get("answer")} for _, t in done]}
        if time.monotonic() > deadline:
            return {"all_done": False, "timed_out": True, "pending": pending, "results": []}
        await asyncio.sleep(0.5)


if __name__ == "__main__":
    mcp.run()
