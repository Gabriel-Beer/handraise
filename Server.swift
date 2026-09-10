// handraise MCP server: agents put tasks and questions on the screen overlay, then get the human's answers back.
// JSON-RPC over stdio, the handful of MCP methods Claude Code uses, no SDK.
// Delivery: the moment a batch is ready the server posts a message into the Claude Code session that spawned
// it, over the session's inbox socket (cross-session messaging, on by default), and the agent calls
// wait_for_user to collect and acknowledge. wait_for_user also blocks when called early.
// Files under ~/.handraise:
//   tasks/<prio>-<ns>.json  {title, session, ask, done, answer, send_now}  the overlay flips done/answer/send_now
//   sessions/<sid>.json     {pid, cwd, name, resume}                       the overlay checks pid to see if we're alive
import Foundation

typealias Dict = [String: Any]
struct Fail: Error, CustomStringConvertible { let description: String }

let fm = FileManager.default
let home = URL(fileURLWithPath: NSHomeDirectory())
let root = home.appendingPathComponent(".handraise")
let tasksDir = root.appendingPathComponent("tasks"), sessionsDir = root.appendingPathComponent("sessions")
let env = ProcessInfo.processInfo.environment
let sid = env["CLAUDE_CODE_SESSION_ID"] ?? String(getppid())
let inbox = env["CLAUDE_CODE_MESSAGING_SOCKET"], token = env["CLAUDE_CODE_MESSAGING_TOKEN"] ?? ""
let instructions = "handraise shows your tasks and questions to the user on a screen overlay. " + (inbox != nil
    ? "When a batch is ready you receive a message from handraise listing the finished tasks and answers; call "
        + "wait_for_user then, it returns immediately with the results and clears them from the screen. You do not need "
        + "to block for them."
    : "This session has no inbox to notify you, so call wait_for_user right after adding your tasks; it blocks until "
        + "the user is done.")
let lock = NSLock()
var waiting = 0  // wait_for_user calls in progress; the doorbell stays quiet while one is pending
let out = FileHandle.standardOutput, outLock = NSLock()

// MARK: files

func json(_ v: Any) -> Data { (try? JSONSerialization.data(withJSONObject: v, options: .withoutEscapingSlashes)) ?? Data() }
func load(_ url: URL) -> Dict? { (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? Dict } }

func write(_ url: URL, _ v: Dict) {  // temp + rename, so the overlay never reads a half-written file
    let tmp = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent)
    try? json(v).write(to: tmp)
    rename(tmp.path, url.path)
}

func files() -> [URL] {
    ((try? fm.contentsOfDirectory(atPath: tasksDir.path)) ?? []).filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
        .sorted().map { tasksDir.appendingPathComponent($0) }
}

func mine() -> [(URL, Dict)] {
    files().compactMap { u in load(u).flatMap { $0["session"] as? String == sid ? (u, $0) : nil } }
}

struct Status { let done: [(URL, Dict)], pending: [String], ready: Bool }

/// ready when nothing is pending, or the user pressed send-now on something
func status() -> Status {
    let tasks = mine()
    let done = tasks.filter { $0.1["done"] as? Bool == true }
    let pending = tasks.filter { $0.1["done"] as? Bool != true }.map { $0.1["title"] as? String ?? "" }
    return Status(done: done, pending: pending,
                  ready: tasks.isEmpty || pending.isEmpty || done.contains { $0.1["send_now"] as? Bool == true })
}

/// `claude --resume` takes the transcript filename; the env id can be a later rotation that only appears inside
/// the entries, so fall back to scanning the tail of recently written transcripts.
func resumeId() -> String {
    let projects = home.appendingPathComponent(".claude/projects")
    let dirs = ((try? fm.contentsOfDirectory(atPath: projects.path)) ?? []).map { projects.appendingPathComponent($0) }
    if dirs.contains(where: { fm.fileExists(atPath: $0.appendingPathComponent(sid + ".jsonl").path) }) { return sid }
    var fresh: [(URL, Date)] = []
    for d in dirs {
        for f in (try? fm.contentsOfDirectory(atPath: d.path)) ?? [] where f.hasSuffix(".jsonl") {
            let u = d.appendingPathComponent(f)
            if let m = (try? fm.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date, m.timeIntervalSinceNow > -3600 {
                fresh.append((u, m))
            }
        }
    }
    let needle = Data("\"session_id\":\"\(sid)\"".utf8)
    for (u, _) in fresh.sorted(by: { $0.1 > $1.1 }) {
        guard let h = try? FileHandle(forReadingFrom: u), let size = try? h.seekToEnd() else { continue }
        try? h.seek(toOffset: size > 2_000_000 ? size - 2_000_000 : 0)  // ponytail: last 2MB only, the rotated id lives in the newest entries
        if let tail = try? h.readToEnd(), tail.range(of: needle) != nil { return u.deletingPathExtension().lastPathComponent }
    }
    return sid
}

let resume = resumeId()

func announce() {
    write(sessionsDir.appendingPathComponent(sid + ".json"),
          ["pid": Int(getpid()), "cwd": fm.currentDirectoryPath,
           "name": URL(fileURLWithPath: fm.currentDirectoryPath).lastPathComponent, "resume": resume])
}

// MARK: tools

let addTask: Dict = [
    "name": "add_task",
    "description": "Show a task on the user's screen overlay. priority 1 = most urgent, bigger = less urgent. "
        + "ask=true when you need a text answer back (\"check X and tell me what you see\"). "
        + "Afterwards call wait_for_user to get the results.",
    "inputSchema": ["type": "object", "required": ["title"], "properties": [
        "title": ["type": "string"], "priority": ["type": "integer", "default": 5], "ask": ["type": "boolean", "default": false]]]]
let listTasks: Dict = [
    "name": "list_tasks", "description": "Every task on screen, all agents, most urgent first.",
    "inputSchema": ["type": "object", "properties": Dict()]]
let removeTask: Dict = [
    "name": "remove_task", "description": "Remove a task by id (from list_tasks).",
    "inputSchema": ["type": "object", "required": ["id"], "properties": ["id": ["type": "string"]]]]
let waitForUser: Dict = [
    "name": "wait_for_user",
    "description": "Block until the user finished all your tasks (all_done=true) or pressed \"send now\" on one. "
        + "Returns the finished tasks with their answers and clears them. On timeout you get what is still pending; "
        + "just call again (the default stays under Claude Code's 30 min idle limit for stdio tools).",
    "inputSchema": ["type": "object", "properties": ["timeout_seconds": ["type": "integer", "default": 1500]]]]
let tools = [addTask, listTasks, removeTask, waitForUser]

func busy() -> Bool { lock.lock(); defer { lock.unlock() }; return waiting > 0 }
func bump(_ d: Int) { lock.lock(); waiting += d; lock.unlock() }

func call(_ name: String, _ a: Dict) throws -> Any {
    switch name {
    case "add_task":
        let title = (a["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let p = max(0, min(999, a["priority"] as? Int ?? 5))
        let file = String(format: "%03d-%llu.json", p, UInt64(Date().timeIntervalSince1970 * 1e9))
        write(tasksDir.appendingPathComponent(file), ["title": title, "session": sid, "ask": a["ask"] as? Bool ?? false,
                                                     "done": false, "answer": NSNull(), "send_now": false])
        return file
    case "list_tasks":
        return files().compactMap { u -> Dict? in
            guard var t = load(u) else { return nil }
            t["id"] = u.lastPathComponent
            t["priority"] = Int(u.lastPathComponent.prefix(3)) ?? 0
            return t
        }
    case "remove_task":
        guard let id = a["id"] as? String, !id.isEmpty, !id.hasPrefix("."), !id.contains("/") else { throw Fail(description: "bad id") }
        try? fm.removeItem(at: tasksDir.appendingPathComponent(id))
        return "ok"
    case "wait_for_user":
        bump(1)
        defer { bump(-1) }
        let deadline = Date().addingTimeInterval(TimeInterval(a["timeout_seconds"] as? Int ?? 1500))
        while true {
            let s = status()
            if s.ready {
                for (u, _) in s.done { try? fm.removeItem(at: u) }
                return ["all_done": s.pending.isEmpty, "pending": s.pending,
                        "results": s.done.map { ["title": $0.1["title"] ?? "", "answer": $0.1["answer"] ?? NSNull()] }]
            }
            if Date() > deadline { return ["all_done": false, "timed_out": true, "pending": s.pending, "results": []] }
            Thread.sleep(forTimeInterval: 0.5)
        }
    default:
        throw Fail(description: "unknown tool \(name)")
    }
}

// MARK: doorbell

/// Push a message into the session that spawned us, over its inbox socket (Claude Code cross-session messaging).
/// Claude Code sees we are its own child, so it is delivered without an approval dialog.
func post(_ content: String) -> Bool {
    guard let inbox else { return false }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let path = Array(inbox.utf8)
    guard withUnsafeMutableBytes(of: &addr.sun_path, { path.count < $0.count ? { $0.copyBytes(from: path); return true }($0) : false }) else { return false }
    var tv = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard rc == 0 else { return false }
    var data = Data()
    let lines: [Dict] = [["type": "auth", "token": token],
                         ["type": "user", "from": "handraise", "message": ["role": "user", "content": content]]]
    for m in lines { data.append(json(m)); data.append(0x0A) }
    return data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) } == data.count
}

/// Ring the session once per ready batch, unless an agent is already blocked in wait_for_user.
func doorbell() {
    var rung: [String]? = nil
    while inbox != nil {
        Thread.sleep(forTimeInterval: 0.5)
        let s = status()
        let key = s.done.map { $0.0.lastPathComponent }
        if !(s.ready && !s.done.isEmpty) || busy() || key == rung { continue }
        let lines = s.done.map { t -> String in
            let answer = t.1["answer"] as? String ?? ""
            return "- " + (t.1["title"] as? String ?? "") + (answer.isEmpty ? "" : " -> " + answer)
        }
        let head = s.pending.isEmpty ? "handraise: the user finished all your tasks." : "handraise: the user sent one answer early."
        let tail = "Call wait_for_user to collect and acknowledge them; that clears them from the overlay."
        if post(([head] + lines + [tail]).joined(separator: "\n")) { rung = key }
    }
}

// MARK: JSON-RPC over stdio

func send(_ msg: Dict) { outLock.lock(); out.write(json(msg) + Data([0x0A])); outLock.unlock() }

func handle(_ req: Dict) {
    guard let id = req["id"] else { return }  // notifications (initialized, cancelled) need no answer
    let params = req["params"] as? Dict ?? [:]
    switch req["method"] as? String ?? "" {
    case "initialize":
        send(["jsonrpc": "2.0", "id": id, "result": [
            "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18", "capabilities": ["tools": Dict()],
            "serverInfo": ["name": "handraise", "version": "0.4.0"], "instructions": instructions]])
    case "ping": send(["jsonrpc": "2.0", "id": id, "result": Dict()])
    case "tools/list": send(["jsonrpc": "2.0", "id": id, "result": ["tools": tools]])
    case "resources/list": send(["jsonrpc": "2.0", "id": id, "result": ["resources": [Any]()]])
    case "prompts/list": send(["jsonrpc": "2.0", "id": id, "result": ["prompts": [Any]()]])
    case "tools/call":
        do {
            let r = try call(params["name"] as? String ?? "", params["arguments"] as? Dict ?? [:])
            let text = r as? String ?? String(decoding: json(r), as: UTF8.self)
            send(["jsonrpc": "2.0", "id": id, "result": ["content": [["type": "text", "text": text]]]])
        } catch {
            send(["jsonrpc": "2.0", "id": id, "result": ["content": [["type": "text", "text": "\(error)"]], "isError": true]])
        }
    case let m: send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(m)"]])
    }
}

for d in [tasksDir, sessionsDir] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
announce()
Thread.detachNewThread(doorbell)
let inflight = DispatchGroup()
while let line = readLine() {
    guard let req = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? Dict else { continue }
    inflight.enter()
    Thread.detachNewThread { handle(req); inflight.leave() }
}
_ = inflight.wait(timeout: .now() + 2)  // stdin closed: let a quick answer out, but never hang on a blocked wait_for_user
