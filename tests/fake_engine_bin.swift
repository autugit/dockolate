// 假引擎（给 tests/verify_adapters.sh 用）：编出来的二进制**名字本身就是引擎特征词**，
// 这样「进程指纹 → 引擎名」这条外部签名表路径才能被端到端验证。
// 用法：<binary-name> <port>
// 响应：/v1/models → {"object":"list","data":[]}；/api/ps → {"models":[]}；其它 404
import Foundation

let port = UInt16(CommandLine.arguments.count > 1 ? (UInt16(CommandLine.arguments[1]) ?? 19800) : 19800)
let fd = socket(AF_INET, SOCK_STREAM, 0)
guard fd >= 0 else { exit(1) }
var yes: Int32 = 1
setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
var addr = sockaddr_in()
addr.sin_family = sa_family_t(AF_INET)
addr.sin_port = port.bigEndian
addr.sin_addr.s_addr = inet_addr("127.0.0.1")
let bindResult = withUnsafePointer(to: &addr) { p in
    p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
}
guard bindResult == 0, listen(fd, 16) == 0 else { exit(2) }

func respond(_ c: Int32, status: String, body: String) {
    let payload = body.data(using: .utf8) ?? Data()
    var head = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\n"
    head += "Content-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
    _ = head.withCString { write(c, $0, strlen($0)) }
    payload.withUnsafeBytes { _ = write(c, $0.baseAddress, payload.count) }
    close(c)
}

while true {
    let client = accept(fd, nil, nil)
    if client < 0 { continue }
    var buf = [UInt8](repeating: 0, count: 4096)
    let n = read(client, &buf, buf.count)
    guard n > 0 else { close(client); continue }
    let request = String(decoding: buf[0..<n], as: UTF8.self)
    let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
    let bare = path.split(separator: "?").first.map(String.init) ?? path
    switch bare {
    case "/v1/models": respond(client, status: "200 OK", body: "{\"object\":\"list\",\"data\":[]}")
    case "/api/ps":    respond(client, status: "200 OK", body: "{\"models\":[]}")
    default:           respond(client, status: "404 Not Found", body: "{}")
    }
}
