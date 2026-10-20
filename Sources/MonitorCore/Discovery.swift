import Foundation
import Network

/// Lista as câmeras Blackmagic na rede pelo Bonjour (`_http._tcp` com TXT
/// `capabilities=cameraControl`) e resolve o IP de cada uma.
public final class Discovery {
    public struct Camera: Hashable, Identifiable, Sendable {
        public let service: String
        public let host: String
        public var id: String { service }

        public init(service: String, host: String) {
            self.service = service
            self.host = host
        }
    }

    public var onChange: (([Camera]) -> Void)?

    private let queue = DispatchQueue(label: "discovery")
    private var browser: NWBrowser?
    private var resolved: [String: Camera] = [:]
    private var present: Set<String> = []

    public init() {}

    public func start() {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_http._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in self?.update(results) }
        browser.start(queue: queue)
        self.browser = browser
    }

    public func stop() { browser?.cancel() }

    private func update(_ results: Set<NWBrowser.Result>) {
        let cameras = results.filter { result in
            guard case .bonjour(let txt) = result.metadata else { return false }
            return txt["capabilities"]?.contains("cameraControl") == true
        }
        present = Set(cameras.compactMap(Self.serviceName))
        resolved = resolved.filter { present.contains($0.key) }
        publish()
        for result in cameras {
            guard let name = Self.serviceName(result), resolved[name] == nil else { continue }
            resolve(result.endpoint, name: name)
        }
    }

    private func resolve(_ endpoint: NWEndpoint, name: String) {
        // IPv4: o SRT e o endereço local do Mac (`StreamSession.localAddress`) são IPv4.
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let connection = NWConnection(to: endpoint, using: parameters)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if case .hostPort(let host, _) = connection.currentPath?.remoteEndpoint {
                    var address = "\(host)"
                    if let scope = address.firstIndex(of: "%") { address = String(address[..<scope]) }
                    if self.present.contains(name), !address.contains(":") {
                        self.resolved[name] = Camera(service: name, host: address)
                        self.publish()
                    }
                }
                connection.cancel()
            case .failed, .waiting:
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func publish() {
        let cameras = resolved.values.sorted { $0.service < $1.service }
        onChange?(cameras)
    }

    private static func serviceName(_ result: NWBrowser.Result) -> String? {
        if case .service(let name, _, _, _) = result.endpoint { return name }
        return nil
    }
}
