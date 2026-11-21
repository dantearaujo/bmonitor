import Foundation
import Testing
@testable import MonitorCore

private let identity = """
    # Red varies fastest
    TITLE "Identity"
    LUT_3D_SIZE 2
    0 0 0
    1 0 0
    0 1 0
    1 1 0
    0 0 1
    1 0 1
    0 1 1
    1 1 1 # white
    """

@Test func parsesColorCubeIntoRGBA() throws {
    let cube = try ColorCube(identity + "\nDOMAIN_MIN -0.1 0 0\nDOMAIN_MAX 1.1 1 1")
    #expect(cube.dimension == 2)
    #expect(cube.minimum == SIMD3(-0.1, 0, 0))
    #expect(cube.maximum == SIMD3(1.1, 1, 1))
    let floats = cube.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    #expect(floats.count == 32)
    #expect(Array(floats[4..<8]) == [1, 0, 0, 1])
    #expect(Array(floats.suffix(4)) == [1, 1, 1, 1])
}

@Test func rejectsInvalidOrUnsupportedColorCube() {
    #expect(throws: ColorCube.FormatError.self) { try ColorCube("LUT_3D_SIZE 2\n0 0 0") }
    #expect(throws: ColorCube.FormatError.self) { try ColorCube("LUT_1D_SIZE 2\n0 0 0\n1 1 1") }
    #expect(throws: ColorCube.FormatError.self) { try ColorCube(identity + "\n0 0 0") }
    #expect(throws: ColorCube.FormatError.self) { try ColorCube(identity + "\nDOMAIN_MAX 0 1 1") }
}
