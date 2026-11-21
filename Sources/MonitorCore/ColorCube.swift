import Foundation

/// A 3D .cube LUT. Core Image expects the red coordinate to vary fastest and each entry to contain RGBA floats.
public struct ColorCube: Sendable {
    public enum FormatError: Error {
        case invalidData
    }

    public let dimension: Int
    public let data: Data
    public let minimum: SIMD3<Float>
    public let maximum: SIMD3<Float>

    public init(contentsOf url: URL) throws {
        try self.init(String(contentsOf: url, encoding: .utf8))
    }

    public init(_ source: String) throws {
        var dimension = 0
        var minimum = SIMD3<Float>(repeating: 0)
        var maximum = SIMD3<Float>(repeating: 1)
        var rgba: [Float] = []

        for line in source.split(whereSeparator: \.isNewline) {
            let content = line.prefix { $0 != "#" }
            let fields = content.split(whereSeparator: \.isWhitespace)
            guard let first = fields.first else { continue }
            switch first {
            case "TITLE": continue
            case "LUT_3D_SIZE":
                guard dimension == 0, fields.count == 2, let size = Int(fields[1]), (2...128).contains(size) else {
                    throw FormatError.invalidData
                }
                dimension = size
                rgba.reserveCapacity(size * size * size * 4)
            case "DOMAIN_MIN": minimum = try Self.vector(fields.dropFirst())
            case "DOMAIN_MAX": maximum = try Self.vector(fields.dropFirst())
            case "LUT_3D_INPUT_RANGE":
                guard fields.count == 3, let low = Float(fields[1]), let high = Float(fields[2]),
                    low.isFinite, high.isFinite else { throw FormatError.invalidData }
                minimum = SIMD3(repeating: low)
                maximum = SIMD3(repeating: high)
            default:
                guard dimension > 0, rgba.count < dimension * dimension * dimension * 4 else {
                    throw FormatError.invalidData
                }
                let rgb = try Self.vector(fields[...])
                rgba.append(contentsOf: [rgb.x, rgb.y, rgb.z, 1])
            }
        }
        let width = maximum - minimum
        guard dimension > 0, rgba.count == dimension * dimension * dimension * 4,
            width.x.isFinite, width.y.isFinite, width.z.isFinite,
            (1 / width.x).isFinite, (1 / width.y).isFinite, (1 / width.z).isFinite,
            width.x > 0, width.y > 0, width.z > 0
        else { throw FormatError.invalidData }
        self.dimension = dimension
        self.minimum = minimum
        self.maximum = maximum
        data = rgba.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func vector(_ fields: ArraySlice<Substring>) throws -> SIMD3<Float> {
        let values = fields.compactMap { Float($0) }
        guard fields.count == 3, values.count == 3, values.allSatisfy(\.isFinite) else {
            throw FormatError.invalidData
        }
        return SIMD3(values[0], values[1], values[2])
    }
}
