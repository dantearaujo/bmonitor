import CSRT
import Foundation
import Testing

@testable import MonitorCore

/// Transmissor SRT local: conecta em 127.0.0.1:<porta> e manda `count` mensagens de 1316 bytes
/// (7 pacotes TS, como o iPhone), cada uma marcada com o índice no primeiro byte.
private func sendMessages(port: UInt16, count: Int, passphrase: String? = nil) throws {
    srt_startup()
    let socket = srt_create_socket()
    defer { srt_close(socket) }
    if let passphrase {
        var bytes = Array(passphrase.utf8CString)
        srt_setsockflag(socket, SRTO_PASSPHRASE, &bytes, Int32(passphrase.utf8.count))
    }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { srt_connect(socket, $0, Int32(MemoryLayout<sockaddr_in>.size)) }
    }
    try #require(connected != SRT_ERROR, "srt_connect: \(String(cString: srt_getlasterror_str()))")
    for index in 0..<count {
        var message = [CChar](repeating: 0x47, count: 1316)
        message[0] = CChar(truncatingIfNeeded: index)
        #expect(srt_sendmsg(socket, &message, 1316, -1, 1) == 1316)
        usleep(2000)
    }
    usleep(300_000)
}

/// O receptor do app (SRTListener) recebe tudo o que um transmissor SRT manda, na ordem.
/// Confere a libsrt empacotada no app, sem iPhone.
@Test func listenerReceivesLocalStream() throws {
    let listener = SRTListener(port: 9150, latencyMs: 20)
    let port = try listener.listen()
    let received = Received()
    listener.onPayload = { received.append($0) }
    Thread { listener.run() }.start()

    try sendMessages(port: port, count: 30)
    #expect(received.sizes.count == 30)
    #expect(received.sizes.allSatisfy { $0 == 1316 })
    #expect(received.firstBytes == (0..<30).map { UInt8($0) })
}

/// Um par SRT com senha: o handshake e a cifra passam pelo OpenSSL empacotado.
@Test func encryptedPairUsesOpenSSL() throws {
    srt_startup()
    let server = srt_create_socket()
    defer { srt_close(server) }
    let passphrase = "bmonitor-teste-123"
    var bytes = Array(passphrase.utf8CString)
    srt_setsockflag(server, SRTO_PASSPHRASE, &bytes, Int32(passphrase.utf8.count))
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(9160).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { srt_bind(server, $0, Int32(MemoryLayout<sockaddr_in>.size)) }
    }
    try #require(bound != SRT_ERROR && srt_listen(server, 1) != SRT_ERROR)
    let received = Received()
    Thread {
        let socket = srt_accept(server, nil, nil)
        guard socket != SRT_INVALID_SOCK else { return }
        var buffer = [CChar](repeating: 0, count: 1500)
        while true {
            let n = srt_recvmsg(socket, &buffer, 1500)
            if n <= 0 { break }
            buffer.withUnsafeBytes { received.append(UnsafeRawBufferPointer(rebasing: $0[0..<Int(n)])) }
        }
        srt_close(socket)
    }.start()

    try sendMessages(port: 9160, count: 10, passphrase: passphrase)
    #expect(received.sizes.count == 10)
    #expect(received.firstBytes == (0..<10).map { UInt8($0) })
}

private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var payloads: [[UInt8]] = []
    func append(_ bytes: UnsafeRawBufferPointer) { lock.withLock { payloads.append(Array(bytes)) } }
    var sizes: [Int] { lock.withLock { payloads.map(\.count) } }
    var firstBytes: [UInt8] { lock.withLock { payloads.compactMap(\.first) } }
}
