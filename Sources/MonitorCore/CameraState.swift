import CoreGraphics
import Foundation
import Observation

public enum Shutter: Equatable, Hashable {
    case speed(Int)
    case angle(Double)

    /// Corpo do PUT em `/video/shutter`. O ângulo vai em graus (a doc fala em centésimos,
    /// mas o iPhone responde 400) e só é aceito com `measurement` em `ShutterAngle`.
    public var requestBody: [String: Any] {
        switch self {
        case .speed(let s): return ["shutterSpeed": s]
        case .angle(let a): return ["shutterAngle": a]
        }
    }

    /// Valor de `/video/shutter/measurement` que este tipo de shutter exige.
    public var measurement: String {
        switch self {
        case .speed: return "ShutterSpeed"
        case .angle: return "ShutterAngle"
        }
    }

    public var label: String {
        switch self {
        case .speed(let s): return "1/\(s)"
        case .angle(let a): return a.rounded() == a ? "\(Int(a))°" : String(format: "%.1f°", a)
        }
    }
}

public enum Level { case normal, warning, critical }

public struct Lens: Equatable, Hashable, Identifiable {
    public let id: String
    public let zoomFactor: String
    public let focalLength: Int
    public let facing: String
    public let isAvailable: Bool

    /// "2×" para a traseira, "Frontal 0.5×" para a frontal.
    public var label: String {
        let factor = zoomFactor.replacingOccurrences(of: "x", with: "×")
        return facing == "front" ? "Frontal \(factor)" : factor
    }
}

/// Valor atual de cada propriedade da câmera que o app usa. Só muda com o que a câmera
/// confirma pelos eventos; pedidos em voo moram no modelo da interface, não aqui.
@Observable
public final class CameraState {
    public static let properties = [
        "/transports/0/record", "/transports/0/timecode", "/system/videoFormat",
        "/video/iso", "/video/shutter", "/video/whiteBalance", "/video/whiteBalanceTint",
        "/lens/cameras/active", "/media/workingset",
        "/audio/channel/0/input", "/audio/channel/1/input",
        "/livestreams/0",
        "/video/shutter/measurement",
        "/video/supportedISOs", "/video/supportedShutters", "/video/flickerFreeShutters", "/video/autoExposure",
        "/video/whiteBalance/description", "/video/whiteBalanceTint/description",
        "/lens/cameras", "/lens/zoom", "/lens/zoom/description", "/lens/focus", "/lens/opticalImageStabilization",
        "/audio/channel/0/supportedInputs", "/audio/channel/0/level", "/audio/channel/0/input/description",
        "/camera/power", "/system/product",
        "/system/format", "/system/supportedFormats", "/system/dynamicRange", "/system/supportedDynamicRanges",
    ]

    /// Abaixo destes segundos restantes o status vira alerta (decisão de produto).
    public static let warningSeconds = 600
    public static let criticalSeconds = 180

    public var recording = false
    public var clipName: String?
    public var videoFormat = ""
    public var frameRate: Double = 30
    public var videoSize = CGSize(width: 16, height: 9)
    public var iso: Int?
    public var shutter: Shutter?
    public var whiteBalance: Int?
    public var tint: Int?
    public var lens: String?
    public var remainingRecordTime: Int?
    public var audioInputs: [Int: String] = [:]
    public var streamStatus: String?

    public var supportedISOs: [Int] = []
    public var shutterSpeeds: [Int] = []
    public var shutterAngles: [Double] = []
    public var flickerFreeSpeeds: [Int] = []
    public var flickerFreeAngles: [Double] = []
    public var autoExposure = "Off"
    public var shutterMeasurement = "ShutterSpeed"
    public var whiteBalanceRange = 2500...10000
    public var tintRange = -50...50
    public var lenses: [Lens] = []
    public var activeLensID: String?
    public var zoomFocalLength: Double?
    public var zoomNormalized: Double = 0
    public var zoomRange: ClosedRange<Double>?
    public var focus: Double?
    /// Ganho da entrada de áudio, de 0 a 1 (`normalised`; o `gain` só repete o mesmo número).
    public var audioGain: Double?
    public var stabilization = false
    public var availableAudioInputs: [String] = []
    /// Faixa de ganho da entrada atual. O microfone do iPhone publica 1 a 1: não ajusta.
    public var audioGainRange: ClosedRange<Double>?
    /// Bateria do iPhone, de 0 a 100, e se está carregando.
    public var batteryPercent: Int?
    public var batteryCharging = false
    /// "Nome da Câmera" nos ajustes do Blackmagic Camera ("A") e o modelo do iPhone. O nome que
    /// a pessoa deu ao iPhone não sai pela API nem pelo Bonjour.
    public var deviceName: String?
    public var productName: String?

    /// Formato de gravação (`/system/format`) e as opções que o iPhone publica para ele.
    public var recordFormat: RecordFormat?
    public var supportedFormats: [RecordFormat.Option] = []
    public var dynamicRange: String?
    public var supportedDynamicRanges: [String] = []

    /// A opção "sem áudio" vem no idioma do iPhone ("None" em inglês, "Não" em português) e é
    /// a primeira de `supportedInputs` nos dois (conferido em 21/10/2026).
    public var silentInput = "None"

    private var timecodeFrames = 0
    private var timecodeAt = Date.distantPast

    public init() {}

    public func isFlickerFree(_ shutter: Shutter) -> Bool {
        switch shutter {
        case .speed(let s): return flickerFreeSpeeds.contains(s)
        case .angle(let a): return flickerFreeAngles.contains { abs($0 - a) < 0.01 }
        }
    }

    /// Laranja com 20% ou menos, vermelho com 10%: os mesmos pontos em que o iOS avisa de
    /// bateria fraca.
    public var batteryLevel: Level {
        guard let percent = batteryPercent else { return .normal }
        if percent <= 10 { return .critical }
        if percent <= 20 { return .warning }
        return .normal
    }

    public var remainingLevel: Level {
        guard let seconds = remainingRecordTime else { return .normal }
        if seconds < Self.criticalSeconds { return .critical }
        if seconds < Self.warningSeconds { return .warning }
        return .normal
    }

    /// Timecode no instante pedido: parado, é o último que a câmera mandou; gravando, corre
    /// localmente a partir dele até o próximo evento corrigir.
    public func timecode(at now: Date = Date()) -> String {
        var frames = timecodeFrames
        if recording {
            frames += Int((now.timeIntervalSince(timecodeAt) * frameRate).rounded(.down))
        }
        let fps = max(Int(frameRate.rounded()), 1)
        let f = frames % fps
        let s = frames / fps
        return String(format: "%02d:%02d:%02d:%02d", s / 3600 % 24, s / 60 % 60, s % 60, f)
    }

    public func apply(property: String, value: [String: Any], at now: Date = Date()) {
        switch property {
        case "/transports/0/record":
            if let r = value["recording"] as? Bool { recording = r }
            if let name = value["clipName"] as? String { clipName = name }
        case "/transports/0/timecode":
            if let display = value["display"] as? String, let frames = parseTimecode(display) {
                timecodeFrames = frames
                timecodeAt = now
            }
        case "/system/videoFormat":
            if let name = value["name"] as? String { videoFormat = name }
            if let rate = (value["frameRate"] as? String).flatMap(Double.init) ?? (value["frameRate"] as? Double) {
                frameRate = rate
            }
            if let w = value["width"] as? Int, let h = value["height"] as? Int, w > 0, h > 0 {
                videoSize = CGSize(width: w, height: h)
            }
        case "/video/iso":
            iso = value["iso"] as? Int
        case "/video/shutter":
            if let speed = value["shutterSpeed"] as? Int {
                shutter = .speed(speed)
            } else if let raw = number(value["shutterAngle"]) {
                // O PUT usa centésimos de grau; aceita as duas formas na leitura.
                shutter = .angle(raw > 360 ? raw / 100 : raw)
            }
        case "/video/whiteBalance":
            whiteBalance = value["whiteBalance"] as? Int
        case "/video/whiteBalanceTint":
            tint = value["whiteBalanceTint"] as? Int
        case "/lens/cameras/active":
            if let zoom = value["zoomFactor"] as? String {
                lens = zoom.replacingOccurrences(of: "x", with: "×")
            }
            activeLensID = value["id"] as? String ?? activeLensID
        case "/lens/cameras":
            let cameras = value["cameras"] as? [[String: Any]] ?? []
            lenses = cameras.compactMap { c in
                guard let id = c["id"] as? String else { return nil }
                return Lens(
                    id: id, zoomFactor: c["zoomFactor"] as? String ?? "", focalLength: c["focalLength"] as? Int ?? 0,
                    facing: c["facing"] as? String ?? "back", isAvailable: c["isAvailable"] as? Bool ?? true)
            }
            if let active = cameras.first(where: { $0["isActive"] as? Bool == true }) {
                activeLensID = active["id"] as? String
            }
        case "/lens/zoom":
            zoomFocalLength = number(value["focalLength"])
            zoomNormalized = number(value["normalized"]) ?? number(value["normalised"]) ?? zoomNormalized
        case "/lens/zoom/description":
            if let range = value["focalLength"] as? [String: Any], let lo = number(range["min"]),
                let hi = number(range["max"]), lo <= hi
            {
                zoomRange = lo...hi
            }
        case "/lens/focus":
            focus = number(value["normalized"]) ?? number(value["normalised"])
        case "/lens/opticalImageStabilization":
            stabilization = value["enabled"] as? Bool ?? stabilization
        case "/video/supportedISOs":
            supportedISOs = value["supportedISOs"] as? [Int] ?? []
        case "/video/supportedShutters":
            shutterSpeeds = value["shutterSpeeds"] as? [Int] ?? []
            shutterAngles = (value["shutterAngles"] as? [Any] ?? []).compactMap(number)
        case "/video/flickerFreeShutters":
            flickerFreeSpeeds = value["shutterSpeeds"] as? [Int] ?? []
            flickerFreeAngles = (value["shutterAngles"] as? [Any] ?? []).compactMap(number)
        case "/video/shutter/measurement":
            shutterMeasurement = value["measurement"] as? String ?? shutterMeasurement
        case "/video/autoExposure":
            autoExposure = value["mode"] as? String ?? autoExposure
        case "/video/whiteBalance/description":
            if let r = value["whiteBalance"] as? [String: Any], let lo = r["min"] as? Int, let hi = r["max"] as? Int, lo <= hi {
                whiteBalanceRange = lo...hi
            }
        case "/video/whiteBalanceTint/description":
            if let r = value["whiteBalanceTint"] as? [String: Any], let lo = r["min"] as? Int, let hi = r["max"] as? Int,
                lo <= hi
            {
                tintRange = lo...hi
            }
        case "/audio/channel/0/supportedInputs":
            let items = value["items"] as? [[String: Any]] ?? []
            availableAudioInputs = items.filter { $0["available"] as? Bool != false }.compactMap { $0["input"] as? String }
            if let first = items.first?["input"] as? String { silentInput = first }
        case "/media/workingset":
            let disks = value["workingset"] as? [[String: Any]] ?? []
            let active = disks.first { $0["activeDisk"] as? Bool == true } ?? disks.first
            remainingRecordTime = active?["remainingRecordTime"] as? Int
        case "/audio/channel/0/input", "/audio/channel/1/input":
            let channel = property.contains("/1/") ? 1 : 0
            audioInputs[channel] = value["input"] as? String
        case "/audio/channel/0/input/description":
            let range = (value["description"] as? [String: Any])?["gainRange"] as? [String: Any]
            if let lo = number(range?["Min"]), let hi = number(range?["Max"]), lo <= hi {
                audioGainRange = lo...hi
            } else {
                audioGainRange = nil
            }
        case "/camera/power":
            let battery = (value["batteries"] as? [[String: Any]])?.first
            batteryPercent = number(battery?["chargeRemainingPercent"]).map { Int($0.rounded()) }
            batteryCharging = (battery?["statusFlags"] as? [String])?.contains("Battery Is Charging") ?? false
        case "/system/format":
            recordFormat = RecordFormat(value)
        case "/system/supportedFormats":
            supportedFormats = (value["supportedFormats"] as? [[String: Any]] ?? []).compactMap(RecordFormat.Option.init)
        case "/system/dynamicRange":
            dynamicRange = value["dynamicRange"] as? String
        case "/system/supportedDynamicRanges":
            supportedDynamicRanges = value["supportedDynamicRanges"] as? [String] ?? []
        case "/system/product":
            deviceName = value["deviceName"] as? String
            productName = value["productName"] as? String
        case "/audio/channel/0/level":
            audioGain = number(value["normalised"]) ?? number(value["normalized"])
        case "/livestreams/0":
            streamStatus = value["status"] as? String
        default:
            break
        }
    }

    public func isSilent(_ input: String?) -> Bool { input == silentInput }

    /// Algum canal está gravando sem áudio.
    public var recordsSilence: Bool { audioInputs.values.contains(where: isSilent) }

    private func parseTimecode(_ text: String) -> Int? {
        let parts = text.split(whereSeparator: { $0 == ":" || $0 == ";" }).compactMap { Int($0) }
        guard parts.count == 4 else { return nil }
        let fps = max(Int(frameRate.rounded()), 1)
        return ((parts[0] * 60 + parts[1]) * 60 + parts[2]) * fps + parts[3]
    }
}

/// Número do JSON da câmera como Double, venha ele inteiro ou decimal.
private func number(_ value: Any?) -> Double? {
    switch value {
    case let d as Double: return d
    case let i as Int: return Double(i)
    case let n as NSNumber: return n.doubleValue
    default: return nil
    }
}

/// Formato de gravação do Blackmagic Camera. O codec vem com a qualidade depois de dois pontos
/// ("HEVC (H.265):Max"); ProRes 422 só tem "Default".
public struct RecordFormat: Equatable, Sendable {
    public struct Option: Equatable, Sendable {
        /// "4K", "HD", "720p", "Open Gate".
        public let resolution: String
        public let width: Int
        public let height: Int
        public let sensorWidth: Int
        public let sensorHeight: Int
        public let frameRates: [String]
        public let codecs: [String]

        init?(_ value: [String: Any]) {
            guard let descriptor = value["resolutionDescriptor"] as? [String: Any],
                let name = descriptor["description"] as? String,
                let record = value["recordResolution"] as? [String: Any],
                let width = record["width"] as? Int, let height = record["height"] as? Int
            else { return nil }
            let sensor = value["sensorResolution"] as? [String: Any]
            resolution = name
            self.width = width
            self.height = height
            sensorWidth = sensor?["width"] as? Int ?? width
            sensorHeight = sensor?["height"] as? Int ?? height
            frameRates = value["frameRates"] as? [String] ?? []
            codecs = value["codecs"] as? [String] ?? []
        }
    }

    public let resolution: String
    public let width: Int
    public let height: Int
    public let frameRate: String
    public let codec: String
    let offSpeedEnabled: Bool
    let offSpeedFrameRate: Int

    init?(_ value: [String: Any]) {
        guard let rate = value["frameRate"] as? String, let codec = value["codec"] as? String,
            let record = value["recordResolution"] as? [String: Any],
            let width = record["width"] as? Int, let height = record["height"] as? Int
        else { return nil }
        resolution = (value["resolutionDescriptor"] as? [String: Any])?["description"] as? String ?? "\(width)x\(height)"
        self.width = width
        self.height = height
        frameRate = rate
        self.codec = codec
        offSpeedEnabled = value["offSpeedEnabled"] as? Bool ?? false
        offSpeedFrameRate = value["offSpeedFrameRate"] as? Int ?? Int(Double(rate)?.rounded() ?? 30)
    }

    /// "4K 30p".
    public var summary: String { "\(resolution) \(frameRate)p" }

    /// Família do codec sem a qualidade: "HEVC (H.265)".
    public static func family(_ codec: String) -> String { codec.split(separator: ":").first.map(String.init) ?? codec }
    /// Qualidade do codec: "Max", "High"…; "Default" quando não há níveis.
    public static func quality(_ codec: String) -> String { codec.split(separator: ":").dropFirst().first.map(String.init) ?? "Default" }

    /// Corpo do PUT: a câmera exige o objeto inteiro; só com codec, fps e resolução responde
    /// 500 (testado em 21/10/2026).
    public func body(option: Option, frameRate: String, codec: String) -> [String: Any] {
        [
            "codec": codec, "frameRate": frameRate, "offSpeedEnabled": offSpeedEnabled, "offSpeedFrameRate": offSpeedFrameRate,
            "recordResolution": ["width": option.width, "height": option.height],
            "sensorResolution": ["width": option.sensorWidth, "height": option.sensorHeight],
        ]
    }
}
