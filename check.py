"""python3 check.py : drives the real server over raw stdio JSON-RPC (so channel notifications are visible)
and plays the overlay by editing the task files."""
import json
import os
import subprocess
import threading
import time
from pathlib import Path

SID = f"check-{os.getpid()}"
ROOT = Path.home() / ".handraise"
TASKS = ROOT / "tasks"


def mark(name, answer=None, send_now=False):  # what the overlay does on the circle / paper plane
    f = TASKS / name
    f.write_text(json.dumps({**json.loads(f.read_text()), "done": True, "answer": answer, "send_now": send_now}))


p = subprocess.Popen(["uv", "run", "server.py"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                     env={**os.environ, "CLAUDE_CODE_SESSION_ID": SID}, text=True)
lines = []
threading.Thread(target=lambda: [lines.append(json.loads(l)) for l in p.stdout], daemon=True).start()
seq = 0


def send(method, **params):
    p.stdin.write(json.dumps({"jsonrpc": "2.0", "method": method, "params": params}) + "\n")
    p.stdin.flush()


def call(name, **args):
    global seq
    seq += 1
    p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": seq, "method": "tools/call", "params": {"name": name, "arguments": args}}) + "\n")
    p.stdin.flush()
    for _ in range(200):
        for m in lines:
            if m.get("id") == seq:
                r = m["result"]
                return r["content"][0]["text"] if r["content"] else None, r.get("structuredContent", {}).get("result"), r.get("isError")
        time.sleep(0.05)
    raise TimeoutError(name)


def rings():
    return [m["params"] for m in lines if m.get("method") == "notifications/claude/channel"]


try:
    seq += 1
    p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": seq, "method": "initialize", "params": {
        "protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "check", "version": "0"}}}) + "\n")
    p.stdin.flush()
    while not any(m.get("id") == seq for m in lines):
        time.sleep(0.05)
    assert "claude/channel" in lines[-1]["result"]["capabilities"]["experimental"]
    send("notifications/initialized")

    plain, *_ = call("add_task", title="  restart the router ", priority=1)
    sess = json.loads((ROOT / "sessions" / f"{SID}.json").read_text())
    assert sess["cwd"] == os.getcwd() and sess["resume"] == SID and os.kill(sess["pid"], 0) is None, sess
    q, *_ = call("add_task", title="what does the LED show?", priority=2, ask=True)
    lo, *_ = call("add_task", title="later", priority=5000)
    assert lo.startswith("999-"), lo
    ids = [t["id"] for t in call("list_tasks")[1]]
    assert ids.index(plain) < ids.index(q) < ids.index(lo), ids

    r = json.loads(call("wait_for_user", timeout_seconds=1)[0])
    assert r["timed_out"] and {"restart the router", "what does the LED show?"} <= set(r["pending"]), r
    assert not rings()

    mark(q, answer="green", send_now=True)
    time.sleep(1.5)  # the doorbell polls every 0.5s
    assert rings() and "green" in rings()[-1]["content"] and rings()[-1]["meta"]["all_done"] == "false", rings()
    r = json.loads(call("wait_for_user", timeout_seconds=5)[0])
    assert r["results"] == [{"title": "what does the LED show?", "answer": "green"}] and not r["all_done"], r
    assert not (TASKS / q).exists()

    mark(plain), mark(lo)
    time.sleep(1.5)
    assert len(rings()) == 2 and rings()[-1]["meta"]["all_done"] == "true", rings()
    r = json.loads(call("wait_for_user", timeout_seconds=5)[0])
    assert r["all_done"] and {x["title"] for x in r["results"]} == {"restart the router", "later"}, r
    assert not any(t["id"] in (plain, lo) for t in call("list_tasks")[1])

    assert call("remove_task", id="../x")[2] is True
    print("ok")
finally:
    p.terminate()
    (ROOT / "sessions" / f"{SID}.json").unlink(missing_ok=True)
