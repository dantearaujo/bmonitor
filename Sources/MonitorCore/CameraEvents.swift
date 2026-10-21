import Foundation

/// WebSocket de eventos da câmera. Assina as propriedades, entrega cada valor e reconecta
/// sozinho quando a conexão cai. Os callbacks rodam numa fila de fundo.
public final class CameraEvents {
    public var onChange: ((_ property: String, _ value: [String: Any]) -> Void)?
    public var onConnection: ((_ connected: Bool) -> Void)?

    private let url: URL
    private let properties: [String]
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var running = false
    private let watch = DispatchQueue(label: "bmonitor.camera-events")
    private var lastPong = Date()

    public init(host: String, properties: [String]) {
        self.url = URL(string: "wss://\(host):4444/control/api/v1/event/websocket")!
        self.properties = properties
        self.session = URLSession(configuration: .ephemeral, delegate: SelfSignedTrust(host: host), delegateQueue: nil)
    }

    public func start() {
        running = true
        connect()
    }

    public func stop() {
        running = false
        task?.cancel(with: .goingAway, reason: nil)
    }

    private func connect() {
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        let subscribe: [String: Any] = [
            "type": "request", "id": 1,
            "data": ["action": "subscribe", "properties": properties],
        ]
        let text = String(decoding: try! JSONSerialization.data(withJSONObject: subscribe), as: UTF8.self)
        task.send(.string(text)) { [weak self] error in
            if error == nil { self?.onConnection?(true) }
        }
        receive(on: task)
        watch.async {
            self.lastPong = Date()
            self.ping(task)
        }
    }

    /// Ping a cada 2 s. Uma conexão pode morrer calada, sem erro no `receive`: o app ficava
    /// com o REC e o microfone parados no último valor (visto em 21/10/2026). Sem pong em 5 s
    /// (o iPhone responde em ~10 ms), derruba a tarefa e reconecta daqui mesmo: com o Blackmagic
    /// Camera em segundo plano a conexão nova fica pendurada antes de abrir, e cancelada assim
    /// ela não chama o `receive` de volta, então esperar por ele deixava o app em "Sem câmera".
    private func ping(_ task: URLSessionWebSocketTask) {
        watch.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.running, task === self.task else { return }
            if Date().timeIntervalSince(self.lastPong) > 5 {
                print("eventos da câmera sem resposta; reconectando")
                self.task = nil
                task.cancel(with: .abnormalClosure, reason: nil)
                self.reconnect()
                return
            }
            task.sendPing { [weak self] error in
                guard error == nil, let self else { return }
                self.watch.async { self.lastPong = Date() }
            }
            self.ping(task)
        }
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self, task === self.task else { return }
            switch result {
            case .success(let message):
                let data: Data
                switch message {
                case .string(let text): data = Data(text.utf8)
                case .data(let bytes): data = bytes
                @unknown default: data = Data()
                }
                for (property, value) in Self.changes(in: data) { self.onChange?(property, value) }
                self.receive(on: task)
            case .failure:
                self.reconnect()
            }
        }
    }

    private func reconnect() {
        onConnection?(false)
        guard running else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.running else { return }
            self.connect()
        }
    }

    /// Extrai os pares propriedade/valor de uma mensagem: o retrato completo que vem na
    /// resposta ao `subscribe` e cada `propertyValueChanged`.
    static func changes(in message: Data) -> [(String, [String: Any])] {
        guard let root = try? JSONSerialization.jsonObject(with: message) as? [String: Any],
            let data = root["data"] as? [String: Any]
        else { return [] }
        if let values = data["values"] as? [String: Any] {
            return values.map { ($0.key, wrap($0.value)) }
        }
        if data["action"] as? String == "propertyValueChanged", let property = data["property"] as? String,
            let value = data["value"]
        {
            return [(property, wrap(value))]
        }
        return []
    }

    /// Algumas propriedades (`supportedInputs`) chegam como lista solta: vão em `items`.
    private static func wrap(_ value: Any) -> [String: Any] {
        value as? [String: Any] ?? ["items": value]
    }
}

/// Aceita o certificado autoassinado só do host da câmera.
final class SelfSignedTrust: NSObject, URLSessionDelegate {
    private let host: String

    init(host: String) { self.host = host }

    func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust, space.host == host,
            let trust = space.serverTrust
        {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
