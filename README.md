# handraise

A Liquid Glass overlay for macOS where your Claude Code agents raise their hand.
Agents post tasks and questions for you, ranked by priority. You tick them off or
type an answer, and the agent gets everything back in its session.

- One Swift file for the overlay, one Python file for the MCP server, no framework, no database.
- Tasks are plain JSON files in `~/.handraise/tasks/`, so any number of agents can write at once.
- Clicks pass through the card to whatever is behind it, except on the button column.
- The overlay hides itself when there is nothing to do.

## Requirements

- macOS 26 (the card uses Liquid Glass) with the Xcode Command Line Tools for `swiftc`
- [uv](https://docs.astral.sh/uv/) to run the Python server
- [Claude Code](https://claude.com/claude-code)

## Install

```sh
git clone https://github.com/Gabriel-Beer/handraise.git
cd handraise
./install.sh
```

`install.sh` compiles the overlay, registers it as a login item through launchd
(`~/Library/LaunchAgents/com.handraise.overlay.plist`), and adds the `handraise`
MCP server to Claude Code for all your projects. Claude sessions that were already
open need `/mcp` or a restart to see the new tools.

The menu bar gets a small icon with **Hide overlay** and **Quit**. After a Quit, bring
it back with:

```sh
launchctl kickstart gui/$(id -u)/com.handraise.overlay
```

## What an agent does

| Tool | What it does |
|------|--------------|
| `add_task(title, priority=5, ask=False)` | Puts a task on screen. `priority` 1 is the most urgent. `ask=True` means you expect a text answer. |
| `wait_for_user(timeout_seconds=1500)` | Blocks until you finished every task of this agent, or pressed *send now* on one. Returns the finished tasks with their answers and clears them. |
| `list_tasks()` | Everything on screen, from every agent. |
| `remove_task(id)` | Takes a task back. |

A typical exchange, from the agent's side:

```
add_task("Plug the test phone back in", priority=1)
add_task("What does the LED on the router show?", priority=2, ask=True)
wait_for_user()
→ {"all_done": true, "pending": [], "results": [
     {"title": "Plug the test phone back in", "answer": null},
     {"title": "What does the LED on the router show?", "answer": "blinking orange"}]}
```

`wait_for_user` returns early with `timed_out: true` after 25 minutes so it stays under
Claude Code's idle limit for stdio tools; the agent just calls it again.

### Push instead of blocking

Claude Code can let an MCP server push messages into a session (*channels*, a research
preview). Start Claude with the server registered as a channel:

```sh
claude --channels server:handraise
```

Now the agent does not need to block: the moment a batch is ready, the server rings the
session with the answers, and the agent calls `wait_for_user` once to collect and
acknowledge them. The same thing happens right after `claude --channels server:handraise
--resume <id>`, so a dead agent picks up where it left off. An alias keeps it out of
the way:

```sh
alias claude='claude --channels server:handraise'
```

Without the flag nothing changes: the notification is dropped by Claude Code and agents
rely on `wait_for_user`.

## What you do

- **Circle**: finishes a plain task. On a question it opens a text field; Enter saves the answer, Escape closes the field.
- **Paper plane**: same, but delivered to the agent right away instead of waiting for the rest. It appears on hover for plain tasks and next to the field for questions.
- **Cross** (on hover): drops a task you won't do, without answering.
- Only four tasks show at a time, most urgent first, with a `+N more` line for the rest.
- When every task of one agent is done, the card shows *All done* until the agent's next `wait_for_user` collects the results. An agent that never calls it never hears back, so the cross lets you drop them.
- If that agent's session is gone, the card says the answers will be delivered as soon as you restart the agent and puts `claude --channels server:handraise --resume <id>` behind the copy button. The server rings the resumed agent as soon as it connects (see *Push* below). A copy button and a cross to drop the answers sit next to it.

Priority is shown as contrast rather than color: P1 is a solid disc, P4 and beyond are barely there.

## Files

```
~/.handraise/
  tasks/<priority>-<timestamp>.json   {title, session, ask, done, answer, send_now}
  sessions/<session id>.json          {pid, cwd, name, resume}
```

The server writes tasks, the overlay flips `done`, `answer` and `send_now`, and the
server deletes what it delivered. `sessions/` lets the overlay tell whether an agent is
still alive (its MCP server process) and which id resumes it.

To find that resumable id the server reads the tail of your recent Claude Code transcripts
under `~/.claude/projects/`, because the session id Claude Code hands to child processes
can rotate mid-session while the transcript keeps its original name. Nothing leaves your
machine.

## Tuning

All in `Overlay.swift`, then rerun `./install.sh`:

- glass strength: the `0.5` on the `glassEffect` line (0 is no glass, 1 is full frost)
- rows shown at once: `shown`
- width of the click-sensitive column: `hotWidth`
- position: the `resized` closure pins the card to the top-right of the screen that is active at launch

## Check

```sh
python3 check.py
```

Drives the real server over raw stdio JSON-RPC, plays the overlay by editing the task files, and checks the channel notification.

## Uninstall

```sh
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.handraise.overlay.plist
rm ~/Library/LaunchAgents/com.handraise.overlay.plist
claude mcp remove --scope user handraise
rm -rf ~/.handraise
```

## License

MIT
