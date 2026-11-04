import Darwin
import Foundation

enum PortProbe {
  /// True if something accepts TCP connections on 127.0.0.1:port.
  static func isLocalListening(_ port: Int) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    if fd < 0 { return false }
    defer { close(fd) }

    let flags = fcntl(fd, F_GETFL, 0)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(UInt16(port).bigEndian)
    addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

    let rc: Int32 = withUnsafePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
        Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    if rc == 0 { return true }
    if errno == ECONNREFUSED { return false }
    if errno == EISCONN { return true }
    if errno == EINPROGRESS || errno == EALREADY {
      var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
      let pr = poll(&pfd, 1, 200)
      if pr > 0 {
        var soError: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len)
        return soError == 0
      }
    }
    return false
  }

  /// Wait until ports are free, periodically forcing in-app core stop.
  static func waitUntilFree(ports: [Int], attempts: Int = 20, sleepMs: UInt32 = 50)
    -> Bool
  {
    for _ in 0..<attempts {
      if !ports.contains(where: isLocalListening) {
        return true
      }
      if SingBoxCoreLoader.shared.isRunning() {
        try? SingBoxCoreLoader.shared.stop()
      }
      usleep(sleepMs * 1000)
    }
    return !ports.contains(where: isLocalListening)
  }
}
