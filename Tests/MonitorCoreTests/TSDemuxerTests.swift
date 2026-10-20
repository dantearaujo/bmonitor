import Foundation
import Testing

@testable import MonitorCore

/// 1400 pacotes TS reais do livestream do iPhone (HEVC 4K30, AAC), gravados em 20/10.
private func recordedUnits() throws -> [VideoAccessUnit] {
    let url = try #require(Bundle.module.url(forResource: "stream", withExtension: "ts", subdirectory: "Fixtures"))
    let data = try Data(contentsOf: url)
    let demuxer = TSDemuxer()
    var units: [VideoAccessUnit] = []
    demuxer.onVideo = { units.append($0) }
    // Mensagens SRT do app têm 7 pacotes TS (1316 bytes).
    var offset = 0
    while offset < data.count {
        let end = min(offset + 1316, data.count)
        data[offset..<end].withUnsafeBytes { demuxer.feed($0) }
        offset = end
    }
    return units
}

@Test(.enabled(if: hasStreamFixture, "Fixtures/stream.ts ausente")) func findsHEVCAndEmitsFrames() throws {
    let units = try recordedUnits()
    #expect(units.count > 30)
    let pts = units.compactMap(\.pts)
    #expect(pts.count == units.count)
    // 30 fps em 90 kHz: 3000 ticks por quadro (±1 de arredondamento do iPhone), sempre
    // crescente, porque o stream não tem B-frames.
    for (a, b) in zip(pts, pts.dropFirst()) { #expect((2999...3001).contains(b - a)) }
}

@Test(.enabled(if: hasStreamFixture, "Fixtures/stream.ts ausente")) func keyframeCarriesParameterSets() throws {
    let units = try recordedUnits()
    let types = units.map { unit in
        Set(HEVCDecoder.nalUnits(unit.data).compactMap { $0.first.map { ($0 >> 1) & 0x3F } })
    }
    let keyframe = try #require(types.firstIndex { $0.contains(32) })
    #expect(types[keyframe].isSuperset(of: [32, 33, 34]))
}

@Test func splitsAnnexB() {
    let data = Data([0, 0, 0, 1, 0x40, 0x01, 0xAA, 0, 0, 1, 0x42, 0x01, 0, 0, 0, 1, 0x26, 0x01, 0xBB])
    let nals = HEVCDecoder.nalUnits(data)
    #expect(nals == [Data([0x40, 0x01, 0xAA]), Data([0x42, 0x01]), Data([0x26, 0x01, 0xBB])])
}
