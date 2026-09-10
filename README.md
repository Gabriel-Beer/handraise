# handraise

A Liquid Glass overlay for macOS where your Claude Code agents raise their hand.
Agents post tasks and questions for you, ranked by priority. You tick them off or
type an answer, and the agent gets everything back in its session.

- Two Swift files, the overlay and the MCP server, no framework, no dependencies, no database.
- Tasks are plain JSON files in `~/.handraise/tasks/`, so any number of agents can write at once.
- Clicks pass through the card to whatever is behind it, except on the buttons themselves.
- The overlay hides itself when there is nothing to do.

## Requirements

- macOS 26 (the card uses Liquid Glass) with the Xcode Command Line Tools for `swiftc`
- [Claude Code](https://claude.com/claude-code)

## Install

With Homebrew (the repo is its own tap; Homebrew 6 asks you to trust a third-party tap first):

```sh
brew trust --tap https://github.com/Gabriel-Beer/handraise
brew tap gabriel-beer/handraise https://github.com/Gabriel-Beer/handraise
brew install handraise
brew services start handraise
claude mcp add --scope user handraise -- "$(brew --prefix)/opt/handraise/bin/handraise-server"
```

Or from source:

```sh
git clone https://github.com/Gabriel-Beer/handraise.git
cd handraise
./install.sh
```

Both keep the overlay running as a login item (`brew services`, or
`~/Library/LaunchAgents/com.handraise.overlay.plist` from `install.sh`) and add the
`handraise` MCP server to Claude Code for all your projects. Claude sessions that were
already open need `/mcp` or a restart to see the new tools.

The menu bar gets a small icon with **Hide overlay** and **Quit**. After a Quit, bring
it back with `brew services restart handraise`, or for a source install:

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

### How answers get back

Every Claude Code session has an inbox socket for messages from your other sessions
([cross-session messaging](https://code.claude.com/docs/en/cross-session-messaging), on by
default since v2.1.224), and exports its path to the processes it spawns. The server posts
into it the moment a batch is ready, so the agent does not block: it gets a message listing
the finished tasks and answers and calls `wait_for_user` once to collect and acknowledge
them. Claude Code verifies the post comes from the session's own child process, so it is
delivered without an approval dialog, also in bypass-permissions mode. Nothing to enable,
nothing leaves your machine.

The same thing happens right after `claude --resume <id>`, so a dead agent picks up where
it left off. Without an inbox (a `claude -p --bare` session, an older Claude Code) the
server tells the agent to block in `wait_for_user` right after adding its tasks.

## What you do

- **Circle**: finishes a plain task. On a question it opens a text field; Enter saves the answer, Escape closes the field.
- **Paper plane**: same, but delivered to the agent right away instead of waiting for the rest. Hover the circle to reveal it on a plain task; on a question it sits next to the field.
- **Cross**: drops a task you won't do, without answering. Revealed by hovering the circle too.
- Only four tasks show at a time, most urgent first, with a `+N more` line for the rest.
- **Chevron** next to an agent's name: folds that agent's tasks away, leaving the name and how many are waiting; click again to unfold.
- When every task of one agent is done, the card shows *All done* until the agent's next `wait_for_user` collects the results. An agent that never calls it never hears back, so the cross lets you drop them.
- If that agent's session is gone, the card says the answers will be delivered as soon as you restart the agent and puts `claude --resume <id>` behind the copy button, with a cross to drop the answers instead. The server rings the resumed agent as soon as it connects (see *How answers get back* above).

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
- slack around the buttons before clicks pass through: the `insetBy` in the mouse timer
- position: the `resized` closure pins the card to the top-right of the screen that is active at launch

## Check

```sh
swiftc -O -o handraise-server Server.swift && swift Check.swift
```

Drives the real server over raw stdio JSON-RPC, plays the overlay by editing the task files, and stands in for the session inbox to check what the server posts.

## Uninstall

Homebrew:

```sh
brew services stop handraise
brew uninstall handraise
brew untap gabriel-beer/handraise
claude mcp remove --scope user handraise
rm -rf ~/.handraise
```

Source install:

```sh
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.handraise.overlay.plist
rm ~/Library/LaunchAgents/com.handraise.overlay.plist
claude mcp remove --scope user handraise
rm -rf ~/.handraise
```

## License

GPL-3.0-or-later. Copyright (C) 2026 Gabriel Beer.
