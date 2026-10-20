import AVFoundation
import Accelerate

/// AAC com cabeçalho ADTS para PCM float, um quadro por vez, sem fila: cada quadro de 1024
/// amostras sai assim que o PES de áudio fecha.
public final class AudioDecoder {
    /// Um quadro AAC já sem o cabeçalho ADTS.
    public struct ADTSFrame {
        public var objectType: Int
        public var sampleRateIndex: Int
        public var channels: Int
        public var payload: Data

        public var sampleRate: Int {
            sampleRateIndex < Self.rates.count ? Self.rates[sampleRateIndex] : 0
        }

        static let rates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
    }

    public var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?
    private var config: [Int] = []

    public init() {}

    public func decode(_ unit: AudioAccessUnit) {
        for frame in Self.adtsFrames(unit.data) { decode(frame) }
    }

    private func decode(_ frame: ADTSFrame) {
        let wanted = [frame.objectType, frame.sampleRateIndex, frame.channels]
        if config != wanted, !setUp(frame) { return }
        guard let converter, let inputFormat, let outputFormat else { return }

        let size = frame.payload.count
        let compressed = AVAudioCompressedBuffer(format: inputFormat, packetCapacity: 1, maximumPacketSize: size)
        frame.payload.withUnsafeBytes { compressed.data.copyMemory(from: $0.baseAddress!, byteCount: size) }
        compressed.byteLength = UInt32(size)
        compressed.packetCount = 1
        compressed.packetDescriptions?[0] = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(size))

        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 1024) else { return }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return compressed
        }
        if status != .error, output.frameLength > 0 { onBuffer?(output) }
    }

    private func setUp(_ frame: ADTSFrame) -> Bool {
        var description = AudioStreamBasicDescription(
            mSampleRate: Double(frame.sampleRate), mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: AudioFormatFlags(frame.objectType), mBytesPerPacket: 0, mFramesPerPacket: 1024,
            mBytesPerFrame: 0, mChannelsPerFrame: UInt32(frame.channels), mBitsPerChannel: 0, mReserved: 0)
        guard let input = AVAudioFormat(streamDescription: &description),
            let output = AVAudioFormat(standardFormatWithSampleRate: Double(frame.sampleRate), channels: UInt32(frame.channels))
        else { return false }
        // AudioSpecificConfig de 2 bytes, montado do próprio ADTS.
        let asc = UInt16(frame.objectType) << 11 | UInt16(frame.sampleRateIndex) << 7 | UInt16(frame.channels) << 3
        input.magicCookie = Data([UInt8(asc >> 8), UInt8(asc & 0xFF)])
        guard let converter = AVAudioConverter(from: input, to: output) else { return false }
        self.converter = converter
        inputFormat = input
        outputFormat = output
        config = [frame.objectType, frame.sampleRateIndex, frame.channels]
        return true
    }

    /// Separa os quadros ADTS de um PES.
    public static func adtsFrames(_ data: Data) -> [ADTSFrame] {
        var frames: [ADTSFrame] = []
        let bytes = [UInt8](data)
        var i = 0
        while i + 7 <= bytes.count {
            guard bytes[i] == 0xFF, bytes[i + 1] & 0xF6 == 0xF0 else {
                i += 1
                continue
            }
            let headerLength = bytes[i + 1] & 0x01 != 0 ? 7 : 9
            let length = Int(bytes[i + 3] & 0x03) << 11 | Int(bytes[i + 4]) << 3 | Int(bytes[i + 5]) >> 5
            guard length > headerLength, i + length <= bytes.count else { break }
            frames.append(
                ADTSFrame(
                    objectType: Int(bytes[i + 2] >> 6) + 1,
                    sampleRateIndex: Int(bytes[i + 2] >> 2) & 0x0F,
                    channels: Int(bytes[i + 2] & 0x01) << 2 | Int(bytes[i + 3]) >> 6,
                    payload: Data(bytes[(i + headerLength)..<(i + length)])))
            i += length
        }
        return frames
    }
}

/// Pico e RMS de um canal, em amplitude linear (0 a 1).
public struct AudioLevels: Equatable {
    public var peak: Float
    public var rms: Float

    public static func measure(_ buffer: AVAudioPCMBuffer) -> [AudioLevels] {
        guard let data = buffer.floatChannelData else { return [] }
        let count = vDSP_Length(buffer.frameLength)
        return (0..<Int(buffer.format.channelCount)).map { channel in
            var peak: Float = 0
            var rms: Float = 0
            vDSP_maxmgv(data[channel], 1, &peak, count)
            vDSP_rmsqv(data[channel], 1, &rms, count)
            return AudioLevels(peak: peak, rms: rms)
        }
    }

    /// dBFS, com piso em -120 para o silêncio digital.
    public static func decibels(_ amplitude: Float) -> Float {
        amplitude <= 0.000001 ? -120 : 20 * log10(amplitude)
    }
}

/// Escala e zonas do medidor do Blackmagic Camera (PPM, referência -20 dBFS), lidas da figura
/// do medidor no manual da Blackmagic: -20 dBFS cai no meio do trilho, cada 5 dB acima dele
/// ocupa 1/8 e a parte de baixo é comprimida até -60.
public enum AudioScale {
    public enum Zone { case green, yellow, red }

    /// Pares (dBFS, posição de 0 a 1) das marcas da escala.
    public static let marks: [(db: Float, position: Float)] = [
        (-60, 0), (-50, 0.075), (-40, 0.15), (-30, 0.3), (-20, 0.5), (-15, 0.625), (-10, 0.75), (-5, 0.875), (0, 1),
    ]
    /// Fim do verde (referência do PPM) e início do vermelho.
    public static let yellowFrom: Float = -20
    public static let redFrom: Float = -9

    public static func position(_ db: Float) -> Float {
        guard db > marks[0].db else { return 0 }
        guard db < 0 else { return 1 }
        for (a, b) in zip(marks, marks.dropFirst()) where db <= b.db {
            return a.position + (db - a.db) / (b.db - a.db) * (b.position - a.position)
        }
        return 1
    }

    public static func zone(_ db: Float) -> Zone {
        db >= redFrom ? .red : db >= yellowFrom ? .yellow : .green
    }
}
