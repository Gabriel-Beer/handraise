# Contributing

Issues and pull requests are welcome. For anything bigger than a fix, open an issue first so we can agree on the shape.

## Build and check

```sh
swiftc -O -o handraise-server Server.swift && swift Check.swift   # must print "ok"
./install.sh                                                        # rebuilds and relaunches the overlay
```

`Check.swift` drives the real server over stdio and edits task files the way the overlay does. It runs on every push and
pull request (macOS 26). The overlay itself has no automated check, so describe what you clicked through in the PR,
ideally with a screenshot.

## House style

- One file per program (`Server.swift`, `Overlay.swift`), Swift only, no packages or dependencies.
- The task files under `~/.handraise` are the whole protocol between server and overlay. If you change their shape,
  change both sides and the *Files* section of the README in the same PR.
- Comments explain why, not what. Commit messages are one sentence on the why.
- New behavior the server can show gets a line in `Check.swift` that fails without it.

## Releasing

Bump the version in `Info.plist` (`CFBundleShortVersionString` and `CFBundleVersion`) and in `Server.swift`
(`serverInfo`), tag `vX.Y.Z`, push the tag, then point `Formula/handraise.rb` at the new tag and its commit.

## Security

Please report anything that could expose answers or let another process post into a session privately, through
[GitHub's private vulnerability reporting](https://github.com/Gabriel-Beer/handraise/security/advisories/new), not in a
public issue.
