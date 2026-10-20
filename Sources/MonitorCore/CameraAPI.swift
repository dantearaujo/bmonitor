import Foundation

/// Cliente da REST API da Blackmagic na porta 4444 do iPhone.
/// O certificado é autoassinado: a confiança vale só para o host da câmera.
public final class CameraAPI {
    public struct HTTPError: Error, CustomStringConvertible {
        public let method: String
        public let path: String
        public let status: Int
        public var description: String { "\(method) \(path) → HTTP \(status)" }
    }

    public let host: String
    private let base: URL
    private let session: URLSession

    public init(host: String) {
        self.host = host
        self.base = URL(string: "https://\(host):4444/control/api/v1")!
        self.session = URLSession(configuration: .ephemeral, delegate: SelfSignedTrust(host: host), delegateQueue: nil)
    }

    public func activePlatform() async throws -> [String: Any] {
        let data = try await send("GET", "/livestreams/0/activePlatform")
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    public func setActivePlatform(_ config: [String: Any]) async throws {
        let body = try JSONSerialization.data(withJSONObject: config)
        try await send("PUT", "/livestreams/0/activePlatform", body: body, type: "application/json")
    }

    public func putCustomPlatform(file: String, xml: String) async throws {
        try await send("PUT", "/livestreams/customPlatforms/\(file)", body: Data(xml.utf8), type: "application/xml")
    }

    public func setRecording(_ recording: Bool) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["recording": recording])
        try await send("PUT", "/transports/0/record", body: body, type: "application/json")
    }

    /// PUT genérico em qualquer propriedade; `body` nil manda o PUT vazio dos gatilhos (`doAuto`).
    public func put(_ path: String, _ body: [String: Any]? = nil) async throws {
        let data = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        try await send("PUT", path, body: data, type: data == nil ? nil : "application/json")
    }

    public func get(_ path: String) async throws -> [String: Any] {
        let data = try await send("GET", path)
        let value = try JSONSerialization.jsonObject(with: data)
        return value as? [String: Any] ?? ["items": value]
    }

    public func delete(_ path: String) async throws { try await send("DELETE", path) }

    public func startStream() async throws { try await send("PUT", "/livestreams/0/start") }
    public func stopStream() async throws { try await send("PUT", "/livestreams/0/stop") }

    @discardableResult
    private func send(_ method: String, _ path: String, body: Data? = nil, type: String? = nil) async throws -> Data {
        var request = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: 5)
        request.httpMethod = method
        request.httpBody = body
        if let type { request.setValue(type, forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw HTTPError(method: method, path: path, status: status) }
        return data
    }
}

/// XML de plataforma customizada (formato dos ATEM) apontando o livestream para o Mac.
public func monitorPlatformXML(macIP: String, port: UInt16) -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <streaming>
      <service>
        <name>Mac Monitor</name>
        <servers>
          <server>
            <name>Mac</name>
            <url>srt://\(macIP):\(port)</url>
          </server>
        </servers>
        <profiles>
          <profile>
            <name>Monitor</name>
            <low-latency/>
            <config resolution="1080p" fps="30">
              <bitrate>8000000</bitrate>
              <audio-bitrate>128000</audio-bitrate>
            </config>
          </profile>
        </profiles>
      </service>
    </streaming>
    """
}
