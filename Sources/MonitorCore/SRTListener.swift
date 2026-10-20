import CSRT
import Darwin

/// Escuta SRT em modo listener. O app do iPhone é o caller.
/// `run()` bloqueia: aceita uma conexão, entrega cada mensagem e volta a aceitar quando ela cai.
public final class SRTListener {
    public struct Stats {
        public var tsbpdDelayMs: Int32
        public var rttMs: Double
        public var lostPackets: Int32
        public var droppedPackets: Int32
    }

    public var onConnect: ((_ negotiatedLatencyMs: Int32) -> Void)?
    public var onDisconnect: (() -> Void)?
    public var onPayload: ((UnsafeRawBufferPointer) -> Void)?

    public struct ListenError: Error, CustomStringConvertible {
        public let ports: ClosedRange<UInt16>
        public let reason: String
        public var description: String { "SRT: nenhuma porta livre entre \(ports.lowerBound) e \(ports.upperBound) (\(reason))" }
    }

    /// Porta em que o listener escuta, definida por `listen()`.
    public private(set) var port: UInt16
    private let latencyMs: Int32
    private var server: SRTSOCKET = SRT_INVALID_SOCK
    private var client: SRTSOCKET = SRT_INVALID_SOCK

    /// `port` é a primeira tentativa; `listen()` sobe até nove portas se ela estiver ocupada.
    public init(port: UInt16, latencyMs: Int32) {
        self.port = port
        self.latencyMs = latencyMs
    }

    /// Abre o socket na primeira porta livre e devolve qual foi.
    @discardableResult
    public func listen() throws -> UInt16 {
        srt_startup()
        let range = port...(port + 9)
        var reason = ""
        for candidate in range {
            let socket = srt_create_socket()
            var latency = latencyMs
            srt_setsockflag(socket, SRTO_RCVLATENCY, &latency, Int32(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = candidate.bigEndian
            addr.sin_addr.s_addr = INADDR_ANY
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    srt_bind(socket, $0, Int32(MemoryLayout<sockaddr_in>.size))
                }
            }
            if bound != SRT_ERROR, srt_listen(socket, 1) != SRT_ERROR {
                server = socket
                port = candidate
                return candidate
            }
            reason = String(cString: srt_getlasterror_str())
            srt_close(socket)
        }
        throw ListenError(ports: range, reason: reason)
    }

    /// Aceita conexões para sempre. Chama `listen()` antes, se ainda não chamou.
    public func run() {
        if server == SRT_INVALID_SOCK {
            do { try listen() } catch { fatalError("\(error)") }
        }

        var buffer = [UInt8](repeating: 0, count: 1500)
        while true {
            let socket = srt_accept(server, nil, nil)
            guard socket != SRT_INVALID_SOCK else { continue }
            client = socket

            var negotiated: Int32 = 0
            var size = Int32(MemoryLayout<Int32>.size)
            srt_getsockflag(socket, SRTO_RCVLATENCY, &negotiated, &size)
            onConnect?(negotiated)

            while true {
                let n = buffer.withUnsafeMutableBytes {
                    srt_recvmsg(socket, $0.baseAddress!.assumingMemoryBound(to: CChar.self), 1500)
                }
                if n <= 0 { break }
                buffer.withUnsafeBytes { onPayload?(UnsafeRawBufferPointer(rebasing: $0[0..<Int(n)])) }
            }
            client = SRT_INVALID_SOCK
            srt_close(socket)
            onDisconnect?()
        }
    }

    /// Estatísticas da conexão atual, ou nil sem conexão.
    public func stats() -> Stats? {
        let socket = client
        guard socket != SRT_INVALID_SOCK else { return nil }
        var perf = SRT_TRACEBSTATS()
        guard srt_bstats(socket, &perf, 1) != SRT_ERROR else { return nil }
        return Stats(
            tsbpdDelayMs: perf.msRcvTsbPdDelay,
            rttMs: perf.msRTT,
            lostPackets: perf.pktRcvLoss,
            droppedPackets: perf.pktRcvDrop
        )
    }
}
