#!/bin/sh
# Builds Handraise.app and the MCP server, puts the app in ~/Applications, registers it as a login item (launchd),
# and adds the MCP server to Claude Code.
set -e
cd "$(dirname "$0")"
[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 26 ] || { echo "handraise needs macOS 26 or later (Liquid Glass)"; exit 1; }
command -v swiftc >/dev/null || { echo "swiftc not found: run xcode-select --install"; exit 1; }
rm -rf Handraise.app
mkdir -p Handraise.app/Contents/MacOS Handraise.app/Contents/Resources
swiftc -O -o Handraise.app/Contents/MacOS/Handraise Overlay.swift
swiftc -O -o handraise-server Server.swift
cp AppIcon.icns Handraise.app/Contents/Resources/ && cp Info.plist Handraise.app/Contents/
codesign --force --sign - Handraise.app 2>/dev/null || true  # ad hoc, so macOS keeps the app's identity across rebuilds
APP="$HOME/Applications/Handraise.app"
mkdir -p "$HOME/Applications"
rm -rf "$APP" && cp -R Handraise.app "$APP"
# A freshly copied bundle shows a generic icon until LaunchServices registers it.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" && touch "$APP"

PLIST=~/Library/LaunchAgents/com.handraise.overlay.plist
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.handraise.overlay</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/Handraise</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
</dict></plist>
PL
launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

if ! command -v claude >/dev/null; then
  echo "installed Handraise.app, but the claude CLI is not on PATH. Once it is, run:"
  echo "  claude mcp add --scope user handraise -- $PWD/handraise-server"
  exit 0
fi
claude mcp remove --scope user handraise >/dev/null 2>&1 || true
claude mcp add --scope user handraise -- "$PWD/handraise-server"
echo "installed: Handraise.app in ~/Applications and running, MCP server 'handraise' registered. Restart open Claude sessions to see the tools."
