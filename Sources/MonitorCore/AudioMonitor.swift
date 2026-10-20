import AVFoundation

/// Medidor por canal e escuta do som da câmera na saída padrão do Mac.
///
/// Mudo não agenda nada (a saída do Mac nem é tocada). Com som, cada buffer vai para o player
/// assim que decodifica; uma folga de dois quadros AAC absorve a chegada irregular e um teto
/// descarta o que passaria dele, para o atraso do som não crescer além do vídeo.
public final class AudioMonitor: @unchecked Sendable {
    /// Retrato do medidor num instante, em dBFS por canal, já com a balística aplicada.
    public struct Meter {
        /// Barra de pico: sobe na hora e volta devagar.
        public var peaks: [Float]
        /// Marca de pico: segura o máximo por um instante e depois cai.
        public var holds: [Float]
        /// Instante (relógio monotônico, ns) do último buffer; 0 se nenhum chegou.
        public var updatedAt: UInt64
    }

    /// Contagem para conferir o critério "sem cortes por 10 minutos".
    public struct Stats {
        public var buffers = 0
        public var underruns = 0
        public var drops = 0
    }

    /// Folga ao (re)começar: dois quadros AAC (~43 ms a 48 kHz).
    static let cushionFrames: AVAudioFrameCount = 2048
    /// Teto da fila do player, em buffers de 1024 amostras (~128 ms a 48 kHz).
    static let maxQueued = 6
    /// Volta do PPM tipo I (IEC 60268-10): 20 dB em 1,7 s. O manual da Blackmagic descreve
    /// o PPM do app como "peak hold" com "slow fall back", sem dar números.
    static let fallRate: Float = 20 / 1.7
    /// Tempo que a marca de pico segura antes de cair. O manual diz "um instante"; 1 s é escolha.
    static let holdTime: Float = 1

    private let lock = NSLock()
    private var peaks: [Float] = []
    private var updatedAt: UInt64 = 0
    private var holds: [Float] = []
    private var holdAt: [UInt64] = []
    private var queued = 0
    private var stats = Stats()
    private var muted = true
    /// Já tocou desde o último mudo: fila vazia daqui em diante é corte, não começo.
    private var primed = false

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var engineFormat: AVAudioFormat?

    public init() {}

    public var isMuted: Bool {
        get { lock.withLock { muted } }
        set {
            lock.withLock { muted = newValue }
            if newValue {
                player.stop()
                lock.withLock {
                    queued = 0
                    primed = false
                }
            }
        }
    }

    public func meter(at now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Meter {
        lock.withLock {
            let age = Self.seconds(from: updatedAt, to: now)
            let bars = peaks.map { $0 - Self.fallRate * age }
            let marks = holds.indices.map { i in
                let held = Self.seconds(from: holdAt[i], to: now)
                return max(holds[i] - Self.fallRate * max(held - Self.holdTime, 0), bars[i])
            }
            return Meter(peaks: bars, holds: marks, updatedAt: updatedAt)
        }
    }

    /// Entra o pico de um buffer (dBFS por canal) no instante dado.
    func update(levels: [Float], at now: UInt64) {
        let current = meter(at: now)
        lock.withLock {
            if peaks.count != levels.count {
                peaks = levels
                holds = levels
                holdAt = levels.map { _ in now }
                updatedAt = now
                return
            }
            for (i, level) in levels.enumerated() {
                peaks[i] = max(level, current.peaks[i])
                if level >= current.holds[i] {
                    holds[i] = level
                    holdAt[i] = now
                }
            }
            updatedAt = now
        }
    }

    private static func seconds(from start: UInt64, to end: UInt64) -> Float {
        end > start ? Float(end - start) / 1e9 : 0
    }

    public func statistics() -> Stats { lock.withLock { stats } }

    /// Chamado na thread do receptor para cada buffer decodificado.
    public func play(_ buffer: AVAudioPCMBuffer) {
        measure(buffer)
        guard !isMuted, startEngine(for: buffer.format) else { return }

        let backlog = lock.withLock { queued }
        if backlog >= Self.maxQueued {
            lock.withLock { stats.drops += 1 }
            return
        }
        if backlog == 0 {
            lock.withLock {
                if primed { stats.underruns += 1 }
                primed = true
            }
            if let silence = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: Self.cushionFrames) {
                silence.frameLength = Self.cushionFrames
                schedule(silence)
            }
        }
        schedule(buffer)
        if !player.isPlaying { player.play() }
    }

    public func stop() {
        player.stop()
        engine.stop()
    }

    private func schedule(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            queued += 1
            stats.buffers += 1
        }
        player.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { [weak self] _ in
            self?.lock.withLock { self?.queued = max((self?.queued ?? 1) - 1, 0) }
        }
    }

    private func startEngine(for format: AVAudioFormat) -> Bool {
        if engineFormat == format, engine.isRunning { return true }
        if engineFormat == nil { engine.attach(player) }
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engineFormat = format
        do {
            try engine.start()
            return true
        } catch {
            print("áudio: saída do Mac não abriu: \(error)")
            return false
        }
    }

    private func measure(_ buffer: AVAudioPCMBuffer) {
        update(
            levels: AudioLevels.measure(buffer).map { AudioLevels.decibels($0.peak) },
            at: DispatchTime.now().uptimeNanoseconds)
    }
}
