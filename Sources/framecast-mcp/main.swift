// Connects an app that runs MCP servers as commands (Claude Desktop, Claude Code) to Framecast's control link:
// JSON-RPC messages from stdin go to http://127.0.0.1:8095/mcp with the control link's token, answers go to stdout.
// It talks to nothing but Framecast on this Mac.
//   Claude Desktop: "command": "/Applications/Framecast.app/Contents/MacOS/framecast-mcp"
//   --test uses a test launch's link (port 8096) instead.
import Foundation

let test = CommandLine.arguments.contains("--test")
let port = test ? 8096 : 8095
let tokenFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Framecast").appendingPathComponent(test ? "ControlLink (tests)" : "ControlLink").appendingPathComponent("token")

func write(_ obj: Any) {
    guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return }
    FileHandle.standardOutput.write(d + Data([0x0A]))
}

while let line = readLine() {
    guard let data = line.data(using: .utf8), let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
    let token = (try? String(contentsOf: tokenFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
    req.httpMethod = "POST"
    req.timeoutInterval = 30
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.httpBody = data
    let done = DispatchSemaphore(value: 0)
    var answer: Data?, status = 0
    URLSession.shared.dataTask(with: req) { d, r, _ in answer = d; status = (r as? HTTPURLResponse)?.statusCode ?? 0; done.signal() }.resume()
    done.wait()
    guard let id = msg["id"] else { continue }          // a notification: nothing to answer
    if status == 200, let answer, let obj = try? JSONSerialization.jsonObject(with: answer) { write(obj); continue }
    let problem = status == 0 ? "Framecast isn't running, or its control link is off (Framecast › Settings › AI)."
        : status == 401 ? "Framecast didn't accept the control link token. Switch the control link off and on in Framecast › Settings › AI."
        : "Framecast's control link answered with HTTP \(status)."
    write(["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": problem]])
}
