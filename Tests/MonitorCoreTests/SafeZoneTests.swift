import CoreGraphics
import Testing

@testable import MonitorCore

// As medidas vêm das especificações publicadas por cada rede (fontes em `SafeZone.swift`),
// em pixels de um quadro 1080x1920. Se um teste quebrar, a tabela mudou: confira a fonte.

private let frame = CGRect(x: 0, y: 0, width: 1080, height: 1920)

extension [CGRect] {
    /// Tem um retângulo igual a `rect`, com folga de arredondamento das porcentagens.
    fileprivate func has(_ rect: CGRect) -> Bool {
        contains { abs($0.minX - rect.minX) < 0.01 && abs($0.minY - rect.minY) < 0.01 && abs($0.width - rect.width) < 0.01 && abs($0.height - rect.height) < 0.01 }
    }
}

@Test func metaKeeps14PercentTop35Bottom6Sides() {
    let covered = SafeZone.meta.covered(in: frame)
    #expect(covered.has(CGRect(x: 0, y: 0, width: 1080, height: 268.8)))
    #expect(covered.has(CGRect(x: 0, y: 1248, width: 1080, height: 672)))
    #expect(covered.has(CGRect(x: 0, y: 0, width: 64.8, height: 1920)))
    #expect(covered.has(CGRect(x: 1015.2, y: 0, width: 64.8, height: 1920)))
}

@Test func tiktokWidensTheRightColumnBelow840() {
    let covered = SafeZone.tiktok.covered(in: frame)
    #expect(covered.has(CGRect(x: 0, y: 0, width: 1080, height: 240)))
    #expect(covered.has(CGRect(x: 0, y: 1260, width: 1080, height: 660)))
    #expect(covered.has(CGRect(x: 0, y: 0, width: 120, height: 1920)))
    #expect(covered.has(CGRect(x: 960, y: 0, width: 120, height: 840)))
    #expect(covered.has(CGRect(x: 780, y: 840, width: 300, height: 1080)))
}

@Test func shortsCovers288Top672Bottom192Right() {
    let covered = SafeZone.shorts.covered(in: frame)
    #expect(covered.has(CGRect(x: 0, y: 0, width: 1080, height: 288)))
    #expect(covered.has(CGRect(x: 0, y: 1248, width: 1080, height: 672)))
    #expect(covered.has(CGRect(x: 0, y: 0, width: 48, height: 1920)))
    #expect(covered.has(CGRect(x: 888, y: 0, width: 192, height: 1920)))
}

@Test func profileGridShowsTheMiddle1440() {
    let covered = SafeZone.profileGrid.covered(in: frame)
    #expect(covered.count == 2)
    #expect(covered.has(CGRect(x: 0, y: 0, width: 1080, height: 240)))
    #expect(covered.has(CGRect(x: 0, y: 1680, width: 1080, height: 240)))
}

@Test func squareKeepsTheFullWidthMiddle() {
    let video = CGSize(width: 1080, height: 1920)
    let covered = SafeZone.square.covered(in: SafeZone.square.area(in: video))
    #expect(covered.count == 2)
    #expect(covered.has(CGRect(x: 0, y: 0, width: 1080, height: 420)))
    #expect(covered.has(CGRect(x: 0, y: 1500, width: 1080, height: 420)))
}

@Test func squareInLandscapeVideoKeepsTheFullHeightMiddle() {
    let video = CGSize(width: 1920, height: 1080)
    let covered = SafeZone.square.covered(in: SafeZone.square.area(in: video))
    #expect(covered.has(CGRect(x: 0, y: 0, width: 420, height: 1080)))
    #expect(covered.has(CGRect(x: 1500, y: 0, width: 420, height: 1080)))
}

@Test func zonesScaleWithTheFrame() {
    let half = CGRect(x: 10, y: 20, width: 540, height: 960)
    #expect(SafeZone.shorts.covered(in: half).has(CGRect(x: 10, y: 20, width: 540, height: 144)))
}

@Test func verticalFrameInLandscapeVideoIsCenteredFullHeight() {
    let vertical = SafeZone.verticalFrame(in: CGSize(width: 1920, height: 1080))
    #expect(abs(vertical.width - 607.5) < 0.001)
    #expect(vertical.height == 1080)
    #expect(abs(vertical.midX - 960) < 0.001)
}

@Test func portraitVideoUsesTheWholeFrame() {
    #expect(SafeZone.verticalFrame(in: CGSize(width: 1080, height: 1920)) == CGRect(x: 0, y: 0, width: 1080, height: 1920))
}
