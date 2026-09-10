// swift Check.swift : drives the real server (./handraise-server) over stdio JSON-RPC, plays the overlay by
// editing the task files, and stands in for the Claude Code inbox socket to see what the server posts.
import Foundation

typealias Dict = [String: Any]
let fm = FileManager.default
let sid = "check-\(getpid())"
let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".handraise")
let tasks = root.appendingPathComponent("tasks")
let session = root.appendingPathComponent("sessions/\(sid).json")
let inbox = "/tmp/handraise-check-\(getpid()).sock"  // AF_UNIX paths are short, so not the long temp dir
let lock = NSLock()
var posts: [Dict] = []       // every JSON line the server posted into the inbox
var replies: [Int: Dict] = [:]
var seq = 0

func json(_ v: Any) -> Data { try! JSONSerialization.data(withJSONObject: v, options: .withoutEscapingSlashes) }
func parse(_ d: Data) -> Dict? { try? JSONSerialization.jsonObject(with: d) as? Dict }

// The inbox stand-in
let srv = socket(AF_UNIX, SOCK_STREAM, 0)
var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(inbox.utf8)) }
let bound = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(srv, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
}
precondition(bound == 0 && listen(srv, 4) == 0, "cannot listen on \(inbox)")
Thread.detachNewThread {
    while true {
        let c = accept(srv, nil, nil)
        guard c >= 0 else { continue }
        var data = Data(), buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(c, &buf, buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        close(c)
        lock.lock()
        for line in data.split(separator: 0x0A) { if let m = parse(Data(line)) { posts.append(m) } }
        lock.unlock()
    }
}

// The server
let p = Process()
p.executableURL = URL(fileURLWithPath: "./handraise-server")
var e = ProcessInfo.processInfo.environment
e["CLAUDE_CODE_SESSION_ID"] = sid
e["CLAUDE_CODE_MESSAGING_SOCKET"] = inbox
e["CLAUDE_CODE_MESSAGING_TOKEN"] = "tok"
p.environment = e
let stdinPipe = Pipe(), stdoutPipe = Pipe()
p.standardInput = stdinPipe
p.standardOutput = stdoutPipe
p.standardError = FileHandle.nullDevice
try! p.run()
Thread.detachNewThread {
    var buf = Data()
    while true {
        let d = stdoutPipe.fileHandleForReading.availableData
        if d.isEmpty { break }
        buf.append(d)
        while let nl = buf.firstIndex(of: 0x0A) {
            let line = buf.subdata(in: buf.startIndex..<nl)
            buf.removeSubrange(buf.startIndex...nl)
            if let m = parse(line), let id = m["id"] as? Int { lock.lock(); replies[id] = m; lock.unlock() }
        }
    }
}

func cleanup() { p.terminate(); try? fm.removeItem(at: session); unlink(inbox) }
func fail(_ what: String, line: Int = #line) -> Never { print("FAIL line \(line): \(what)"); cleanup(); exit(1) }
func check(_ ok: Bool, _ what: @autoclosure () -> String, line: Int = #line) { if !ok { fail(what(), line: line) } }

func request(_ method: String, _ params: Dict) -> Dict {
    seq += 1
    let id = seq
    stdinPipe.fileHandleForWriting.write(json(["jsonrpc": "2.0", "id": id, "method": method, "params": params]) + Data([0x0A]))
    for _ in 0..<400 {
        lock.lock(); let r = replies[id]; lock.unlock()
        if let r { return r }
        Thread.sleep(forTimeInterval: 0.05)
    }
    fail("no reply to \(method)")
}
func notify(_ method: String) {
    stdinPipe.fileHandleForWriting.write(json(["jsonrpc": "2.0", "method": method, "params": Dict()]) + Data([0x0A]))
}
func call(_ name: String, _ args: Dict = [:]) -> (text: String, error: Bool) {
    let r = request("tools/call", ["name": name, "arguments": args])["result"] as? Dict ?? [:]
    return ((r["content"] as? [Dict])?.first?["text"] as? String ?? "", r["isError"] as? Bool ?? false)
}
func callJSON(_ name: String, _ args: Dict = [:]) -> Any {
    (try? JSONSerialization.jsonObject(with: Data(call(name, args).text.utf8))) ?? NSNull()
}
func mark(_ name: String, answer: String? = nil, sendNow: Bool = false) {  // what the overlay does on the circle / paper plane
    let u = tasks.appendingPathComponent(name)
    var t = parse((try? Data(contentsOf: u)) ?? Data()) ?? [:]
    t["done"] = true
    t["answer"] = answer ?? NSNull()
    t["send_now"] = sendNow
    try! json(t).write(to: u)
}
func snapshot() -> [Dict] { lock.lock(); defer { lock.unlock() }; return posts }
func rings() -> [String] {
    snapshot().filter { $0["type"] as? String == "user" }.compactMap { ($0["message"] as? Dict)?["content"] as? String }
}

let hello = request("initialize", ["protocolVersion": "2025-06-18", "capabilities": Dict(),
                                   "clientInfo": ["name": "check", "version": "0"]])
check(((hello["result"] as? Dict)?["capabilities"] as? Dict)?["tools"] != nil, "initialize: \(hello)")
notify("notifications/initialized")

let plain = call("add_task", ["title": "  restart the router ", "priority": 1]).text
let sess = parse((try? Data(contentsOf: session)) ?? Data()) ?? [:]
check(sess["cwd"] as? String == fm.currentDirectoryPath && sess["resume"] as? String == sid
      && kill(pid_t(sess["pid"] as? Int ?? 0), 0) == 0, "session file: \(sess)")
let q = call("add_task", ["title": "what does the LED show?", "priority": 2, "ask": true]).text
let lo = call("add_task", ["title": "later", "priority": 5000]).text
check(lo.hasPrefix("999-"), "clamp: \(lo)")
let ids = (callJSON("list_tasks") as? [Dict] ?? []).compactMap { $0["id"] as? String }
let (a, b, c) = (ids.firstIndex(of: plain) ?? -1, ids.firstIndex(of: q) ?? -1, ids.firstIndex(of: lo) ?? -1)
check(a >= 0 && a < b && b < c, "order: \(ids)")

var r = callJSON("wait_for_user", ["timeout_seconds": 1]) as? Dict ?? [:]
check(r["timed_out"] as? Bool == true
      && Set(r["pending"] as? [String] ?? []).isSuperset(of: ["restart the router", "what does the LED show?"]), "timeout: \(r)")
check(snapshot().isEmpty, "posted too early: \(snapshot())")

mark(q, answer: "green", sendNow: true)
Thread.sleep(forTimeInterval: 1.5)  // the doorbell polls every 0.5s
check(snapshot().first?["type"] as? String == "auth" && snapshot().first?["token"] as? String == "tok", "auth line: \(snapshot())")
check(rings().last.map { $0.contains("green") && $0.contains("early") } == true, "send-now ring: \(rings())")
r = callJSON("wait_for_user", ["timeout_seconds": 5]) as? Dict ?? [:]
let early = r["results"] as? [Dict] ?? []
check(early.count == 1 && early[0]["title"] as? String == "what does the LED show?" && early[0]["answer"] as? String == "green"
      && r["all_done"] as? Bool == false, "early results: \(r)")
check(!fm.fileExists(atPath: tasks.appendingPathComponent(q).path), "collected file still there")

mark(plain)
mark(lo)
Thread.sleep(forTimeInterval: 1.5)
check(rings().count == 2 && rings()[1].contains("finished all"), "final ring: \(rings())")
r = callJSON("wait_for_user", ["timeout_seconds": 5]) as? Dict ?? [:]
let titles = Set((r["results"] as? [Dict] ?? []).compactMap { $0["title"] as? String })
check(r["all_done"] as? Bool == true && titles == ["restart the router", "later"], "all done: \(r)")
let left = (callJSON("list_tasks") as? [Dict] ?? []).compactMap { $0["id"] as? String }
check(!left.contains(plain) && !left.contains(lo), "not cleared: \(left)")

check(call("remove_task", ["id": "../x"]).error, "path traversal accepted")
print("ok")
cleanup()
