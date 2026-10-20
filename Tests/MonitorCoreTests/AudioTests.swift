import AVFoundation
import Foundation
import Testing

@testable import MonitorCore

/// Os 128 PES de áudio (AAC-LC estéreo 48 kHz, ADTS) do mesmo trecho real do livestream.
private func recordedAudio() throws -> [AudioAccessUnit] {
    let url = try #require(Bundle.module.url(forResource: "stream", withExtension: "ts", subdirectory: "Fixtures"))
    let data = try Data(contentsOf: url)
    let demuxer = TSDemuxer()
    var units: [AudioAccessUnit] = []
    demuxer.onAudio = { units.append($0) }
    var offset = 0
    while offset < data.count {
        let end = min(offset + 1316, data.count)
        data[offset..<end].withUnsafeBytes { demuxer.feed($0) }
        offset = end
    }
    return units
}

@Test(.enabled(if: hasStreamFixture, "Fixtures/stream.ts ausente")) func demuxesAACFrames() throws {
    let units = try recordedAudio()
    let frames = units.flatMap { AudioDecoder.adtsFrames($0.data) }
    // ffprobe conta 128 pacotes AAC no fixture; o último PES pode chegar cortado.
    #expect((127...128).contains(frames.count))
    // 1024 amostras a 48 kHz = 1920 ticks de 90 kHz entre PES.
    let pts = units.compactMap(\.pts)
    #expect(pts.count == units.count)
    for (a, b) in zip(pts, pts.dropFirst()) { #expect((1919...1921).contains(b - a)) }
}

@Test(.enabled(if: hasStreamFixture, "Fixtures/stream.ts ausente")) func readsADTSHeader() throws {
    let units = try recordedAudio()
    let first = try #require(units.first.flatMap { AudioDecoder.adtsFrames($0.data).first })
    #expect(first.sampleRate == 48000)
    #expect(first.channels == 2)
    #expect(first.objectType == 2)  // AAC-LC
}

@Test(.enabled(if: hasStreamFixture, "Fixtures/stream.ts ausente")) func decodesToStereoPCM() throws {
    let units = try recordedAudio()
    let decoder = AudioDecoder()
    var frames = 0
    var peak: Float = 0
    var channels = 0
    decoder.onBuffer = { buffer in
        frames += Int(buffer.frameLength)
        channels = Int(buffer.format.channelCount)
        let levels = AudioLevels.measure(buffer)
        peak = max(peak, levels.map(\.peak).max() ?? 0)
    }
    for unit in units { decoder.decode(unit) }
    #expect(channels == 2)
    #expect(frames >= 127 * 1024)
    // Microfone do iPhone numa sala: há sinal, sem estourar.
    #expect(peak > 0.0001 && peak < 1)
}

@Test func levelsInDecibels() {
    #expect(AudioLevels.decibels(1) == 0)
    #expect(abs(AudioLevels.decibels(0.5) - -6.0206) < 0.001)
    #expect(AudioLevels.decibels(0) == -120)
}

@Test func peakMeterBallistics() {
    let monitor = AudioMonitor()
    let t0: UInt64 = 1_000_000_000
    let second: UInt64 = 1_000_000_000
    monitor.update(levels: [-10, -30], at: t0)
    // Ataque instantâneo.
    #expect(monitor.meter(at: t0).peaks == [-10, -30])
    // PPM tipo I (IEC 60268-10): volta 20 dB em 1,7 s.
    let fallen = monitor.meter(at: t0 + 17 * second / 10)
    #expect(abs(fallen.peaks[0] - -30) < 0.01)
    // A marca de pico segura 1 s e depois cai no mesmo ritmo.
    #expect(monitor.meter(at: t0 + second / 2).holds[0] == -10)
    #expect(abs(monitor.meter(at: t0 + 27 * second / 10).holds[0] - -30) < 0.01)
    // Um pico novo maior que a marca empurra a marca para cima.
    monitor.update(levels: [-5, -30], at: t0 + second / 10)
    #expect(monitor.meter(at: t0 + second / 10).holds[0] == -5)
}

@Test func meterScaleMatchesBlackmagic() {
    // Posições lidas da figura do medidor no manual da Blackmagic.
    #expect(AudioScale.position(-60) == 0)
    #expect(AudioScale.position(-20) == 0.5)
    #expect(AudioScale.position(-10) == 0.75)
    #expect(AudioScale.position(0) == 1)
    #expect(AudioScale.position(-120) == 0)
    #expect(abs(AudioScale.position(-25) - 0.4) < 0.0001)
    #expect(AudioScale.zone(-21) == .green)
    #expect(AudioScale.zone(-12) == .yellow)
    #expect(AudioScale.zone(-8) == .red)
}
