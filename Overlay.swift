import AppKit
import Combine
import SwiftUI

// Floating overlay for ~/.handraise: tasks and questions from Claude agents, grouped by agent session.
let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".handraise")
let tasksDir = root.appendingPathComponent("tasks")
let sessionsDir = root.appendingPathComponent("sessions")

struct Task: Codable, Identifiable, Equatable {
    var id = ""          // filename, not part of the JSON
    var priority = 999   // filename prefix
    var title: String
    var session: String
    var ask: Bool
    var done: Bool
    var answer: String?
    var send_now: Bool
    enum CodingKeys: String, CodingKey { case title, session, ask, done, answer, send_now }
}

struct Session: Codable { var pid: Int32; var cwd: String; var name: String; var resume: String? }

func atomicWrite(_ data: Data, to url: URL) {
    let tmp = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent)
    try? data.write(to: tmp)
    rename(tmp.path, url.path)
}

final class Store: ObservableObject {
    @Published var tasks: [Task] = []            // open ones, plus done ones the agent hasn't collected yet
    @Published var alive: [String: Bool] = [:]   // session id -> its MCP server process still runs
    @Published var armed = false                 // mouse is over a clickable part, so the panel takes events
    @Published var editing: String?              // task id whose answer field is open
    var sessions: [String: Session] = [:]
    private var watcher: DispatchSourceFileSystemObject?

    init() {
        for d in [tasksDir, sessionsDir] {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        let fd = open(tasksDir.path, O_EVTONLY)
        watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        watcher?.setEventHandler { [weak self] in self?.reload() }
        watcher?.resume()
        reload()
    }

    func reload() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: tasksDir.path)) ?? []
        tasks = names.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.compactMap { name -> Task? in
            guard let data = try? Data(contentsOf: tasksDir.appendingPathComponent(name)),
                  var t = try? JSONDecoder().decode(Task.self, from: data) else { return nil }
            t.id = name
            t.priority = Int(name.prefix(3)) ?? 999
            return t
        }.sorted { ($0.priority, $0.id) < ($1.priority, $1.id) }
        refreshSessions()
    }

    func refreshSessions() {
        var a: [String: Bool] = [:]
        for sid in Set(tasks.map(\.session)) {
            if let data = try? Data(contentsOf: sessionsDir.appendingPathComponent(sid + ".json")),
               let s = try? JSONDecoder().decode(Session.self, from: data) {
                sessions[sid] = s
                a[sid] = kill(s.pid, 0) == 0  // ponytail: a reused pid after reboot reads as alive
            } else {
                a[sid] = false
            }
        }
        if a != alive { alive = a }
    }

    func finish(_ t: Task, answer: String? = nil, sendNow: Bool = false) {
        var t = t
        t.done = true
        t.answer = answer
        t.send_now = sendNow
        if let data = try? JSONEncoder().encode(t) { atomicWrite(data, to: tasksDir.appendingPathComponent(t.id)) }
    }

    func discard(session sid: String) {
        for t in tasks where t.session == sid && t.done {
            try? FileManager.default.removeItem(at: tasksDir.appendingPathComponent(t.id))
        }
    }
}

struct IconButton: View {
    let icon: String, hot: String, armed: Bool, action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: hover && armed ? hot : icon)
                .font(.title3)
                .foregroundStyle(hover && armed ? Color.green : Color.white.opacity(0.7))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct Badge: View {  // priority as contrast, not color: P1 is a solid disc, P4+ is barely there
    let p: Int
    var body: some View {
        let level = max(0, min(3, 4 - p))
        Text("\(p)")
            .font(.caption.bold().monospacedDigit())
            .foregroundStyle(level == 3 ? Color.black : .white)
            .frame(width: 24, height: 24)
            .background(Color.white.opacity([0.12, 0.25, 0.45, 1][level]), in: Circle())
    }
}

struct Row: View {
    let task: Task
    @ObservedObject var store: Store
    @State private var text = ""
    @State private var hover = false
    @FocusState private var focused: Bool
    var editing: Bool { store.editing == task.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Badge(p: task.priority)
                Text(task.title).font(.body).lineLimit(3)
                Spacer(minLength: 0)
                if editing || (hover && store.armed && !task.ask) {  // send-now shows up only when it makes sense
                    IconButton(icon: "paperplane", hot: "paperplane.fill", armed: store.armed) { submit(now: true) }
                }
                IconButton(icon: "circle", hot: "checkmark.circle.fill", armed: store.armed) { tap() }
            }
            .onHover { hover = $0 }
            if editing {
                TextField("Answer…", text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Color.white.opacity(0.12), in: .rect(cornerRadius: 8))
                    .padding(.leading, 34)
                    .onAppear { focused = true }
                    .onSubmit { submit(now: false) }
                    .onExitCommand { close() }
            }
        }
    }

    func tap() {
        if !task.ask { store.finish(task); return }
        if !editing { store.editing = task.id; panel.makeKey(); return }
        if text.trimmingCharacters(in: .whitespaces).isEmpty { close() } else { submit(now: false) }
    }

    func submit(now: Bool) {
        let a = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if task.ask && a.isEmpty { return }
        close()
        store.finish(task, answer: task.ask ? a : nil, sendNow: now)
    }

    func close() {
        store.editing = nil
        dropKey()
    }
}

struct CopyButton: View {
    let text: String
    @State private var copied = false
    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.body).foregroundStyle(Color.white.opacity(0.8))
        }
        .buttonStyle(.plain)
    }
}

struct OverlayView: View {
    @ObservedObject var store: Store
    let resized: (CGSize) -> Void
    let shown = 4

    var body: some View {
        let open = store.tasks.filter { !$0.done }
        let visible = Array(open.prefix(shown))
        let sids = store.tasks.map(\.session).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        VStack(alignment: .leading, spacing: 10) {
            ForEach(sids, id: \.self) { sid in
                let mine = visible.filter { $0.session == sid }
                let hasOpen = open.contains { $0.session == sid }
                let hasDone = store.tasks.contains { $0.session == sid && $0.done }
                let alive = store.alive[sid] ?? false
                if !mine.isEmpty || hasDone {
                    VStack(alignment: .leading, spacing: 4) {  // header and its status read as one block
                        Text("\(store.sessions[sid]?.name ?? "agent") · \(sid.prefix(4))").font(.caption).opacity(0.6)
                        if hasDone && !alive {
                            // the prompt makes the resumed agent collect right away instead of waiting to be told
                            let cmd = "claude --resume \(store.sessions[sid]?.resume ?? sid) \"Collect my answers with wait_for_user\""
                            Text("Will be delivered as soon as you restart the agent:").font(.caption).opacity(0.7)
                            HStack(spacing: 8) {
                                Text(cmd).font(.caption.monospaced()).lineLimit(3)
                                Spacer(minLength: 0)
                                CopyButton(text: cmd)
                                IconButton(icon: "xmark.circle", hot: "xmark.circle.fill", armed: store.armed) { store.discard(session: sid) }
                            }
                        } else if hasDone && !hasOpen {
                            HStack(spacing: 8) {
                                Label("All done, waiting for the agent to call wait_for_user", systemImage: "checkmark")
                                    .font(.caption).opacity(0.6)
                                Spacer(minLength: 0)
                                IconButton(icon: "xmark.circle", hot: "xmark.circle.fill", armed: store.armed) { store.discard(session: sid) }
                            }
                        }
                    }
                    ForEach(mine) { Row(task: $0, store: store) }
                }
            }
            if open.count > shown {
                Text("+\(open.count - shown) more").font(.caption).opacity(0.6)
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.7), radius: 2, y: 1)
        .padding(.vertical, 14).padding(.horizontal, 16)
        .frame(width: 320, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.clear.glassEffect(.regular, in: .rect(cornerRadius: 16)).opacity(0.5))  // 0 = no glass, 1 = full frost
        .onGeometryChange(for: CGSize.self) { $0.size } action: { resized($0) }
    }
}

final class KeyPanel: NSPanel { override var canBecomeKey: Bool { true } }  // borderless windows refuse focus otherwise

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 60),
                     styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
panel.level = .floating
panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
panel.isOpaque = false
panel.backgroundColor = .clear
panel.hasShadow = false
panel.hidesOnDeactivate = false
panel.becomesKeyOnlyIfNeeded = true

let store = Store()
panel.contentView = NSHostingView(rootView: OverlayView(store: store) { size in
    // pinned to the screen's top-right corner, height follows the content
    let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
    panel.setFrame(NSRect(x: vf.maxX - 12 - size.width, y: vf.maxY - 16 - size.height,
                          width: size.width, height: size.height), display: true)
})

var hidden = false
func updateVisibility(empty: Bool) { hidden || empty ? panel.orderOut(nil) : panel.orderFrontRegardless() }

// Give keyboard focus back to whatever app had it: re-showing without makeKey drops our key status.
func dropKey() {
    guard panel.isKeyWindow else { return }
    panel.orderOut(nil)
    updateVisibility(empty: store.tasks.isEmpty)
}
let visibility = store.$tasks.sink { updateVisibility(empty: $0.isEmpty) }

// Clicks pass through to whatever is behind, except on the button column, or anywhere while a question needs typing.
let hotWidth = 84.0
Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
    let m = NSEvent.mouseLocation, f = panel.frame
    let typing = store.editing != nil
    let armed = f.contains(m) && (typing || m.x >= f.maxX - hotWidth)
    if panel.ignoresMouseEvents == armed { panel.ignoresMouseEvents = !armed; store.armed = armed }
}
Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in store.refreshSessions() }

// Menu bar item: a priority dot and three shrinking bars, drawn as a template so it follows the bar's theme.
let logo: NSImage = {
    let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
        NSColor.black.setFill()
        NSBezierPath(ovalIn: NSRect(x: 1, y: 12.25, width: 3, height: 3)).fill()
        for (i, w) in [12.0, 9, 6].enumerated() {
            NSBezierPath(roundedRect: NSRect(x: 6, y: 12.5 - Double(i) * 4.5, width: w, height: 2.5),
                         xRadius: 1.25, yRadius: 1.25).fill()
        }
        return true
    }
    img.isTemplate = true
    return img
}()

final class Bar: NSObject {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let toggle = NSMenuItem(title: "Hide overlay", action: #selector(toggleOverlay), keyEquivalent: "")
    override init() {
        super.init()
        item.button?.image = logo
        let menu = NSMenu()
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
    }
    @objc func toggleOverlay() {
        hidden.toggle()
        toggle.title = hidden ? "Show overlay" : "Hide overlay"
        updateVisibility(empty: store.tasks.isEmpty)
    }
}
let bar = Bar()
app.run()
