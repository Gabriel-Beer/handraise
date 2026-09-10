#!/bin/sh
# Builds the overlay, registers it as a login item (launchd), and adds the MCP server to Claude Code.
set -e
cd "$(dirname "$0")"
swiftc -O -o Handraise Overlay.swift
swiftc -O -o handraise-server Server.swift

PLIST=~/Library/LaunchAgents/com.handraise.overlay.plist
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.handraise.overlay</string>
  <key>ProgramArguments</key><array><string>$PWD/Handraise</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
</dict></plist>
PL
launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

claude mcp remove --scope user handraise >/dev/null 2>&1 || true
claude mcp add --scope user handraise -- "$PWD/handraise-server"
echo "installed: overlay running, MCP server 'handraise' registered. Restart open Claude sessions to see the tools."
