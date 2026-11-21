import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Metal
import MonitorCore

/// Processes only the monitor output. If rendering falls behind, the next render starts with the newest frame.
final class LUTPreview: @unchecked Sendable {
    private let queue = DispatchQueue(label: "bmonitor.lut-preview", qos: .userInteractive)
    private let lock = NSLock()
    private var cube: ColorCube?
    private var generation = 0
    private var pending: CVPixelBuffer?
    private var rendering = false

    private lazy var context: CIContext = {
        let options: [CIContextOption: Any] = [.workingColorSpace: NSNull(), .cacheIntermediates: false]
        if let device = MTLCreateSystemDefaultDevice() { return CIContext(mtlDevice: device, options: options) }
        return CIContext(options: options)
    }()
    private var pool: CVPixelBufferPool?
    private var size = CGSize.zero
    private static let displayColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    func setCube(_ cube: ColorCube?) {
        lock.withLock {
            self.cube = cube
            generation += 1
            pending = nil
        }
    }

    func enqueue(_ frame: CVPixelBuffer, into layer: AVSampleBufferDisplayLayer) {
        lock.withLock {
            guard cube != nil else {
                VideoEnqueue.enqueue(frame, into: layer)
                return
            }
            pending = frame
            guard !rendering else { return }
            rendering = true
            queue.async { [self] in renderPending(into: layer) }
        }
    }

    private func renderPending(into layer: AVSampleBufferDisplayLayer) {
        while let (frame, cube, version) = nextFrame() {
            let output = render(frame, cube: cube) ?? frame
            lock.withLock {
                guard generation == version else { return }
                VideoEnqueue.enqueue(output, into: layer)
            }
        }
    }

    private func nextFrame() -> (CVPixelBuffer, ColorCube, Int)? {
        lock.withLock {
            guard let pending, let cube else {
                rendering = false
                return nil
            }
            self.pending = nil
            return (pending, cube, generation)
        }
    }

    private func render(_ frame: CVPixelBuffer, cube: ColorCube) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(frame)
        let height = CVPixelBufferGetHeight(frame)
        let dimensions = CGSize(width: width, height: height)
        if size != dimensions || pool == nil {
            pool = nil
            CVPixelBufferPoolCreate(nil, nil, [
                kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
                kCVPixelBufferMetalCompatibilityKey: true,
            ] as CFDictionary, &pool)
            size = dimensions
        }
        guard let pool else { return nil }
        var output: CVPixelBuffer?
        let limits = [kCVPixelBufferPoolAllocationThresholdKey: 6] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, limits, &output) == kCVReturnSuccess,
            let output else { return nil }

        // .cube tables expect source code values, including log, rather than a linearized image.
        var image = CIImage(cvPixelBuffer: frame, options: [.colorSpace: NSNull()])
        if cube.minimum != .zero || cube.maximum != SIMD3(repeating: 1) {
            let scale = SIMD3<Float>(repeating: 1) / (cube.maximum - cube.minimum)
            let bias = -cube.minimum * scale
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = image
            matrix.rVector = CIVector(x: CGFloat(scale.x), y: 0, z: 0, w: 0)
            matrix.gVector = CIVector(x: 0, y: CGFloat(scale.y), z: 0, w: 0)
            matrix.bVector = CIVector(x: 0, y: 0, z: CGFloat(scale.z), w: 0)
            matrix.biasVector = CIVector(x: CGFloat(bias.x), y: CGFloat(bias.y), z: CGFloat(bias.z), w: 0)
            guard let normalized = matrix.outputImage else { return nil }
            image = normalized
        }
        let filter = CIFilter.colorCube()
        filter.inputImage = image
        filter.cubeDimension = Float(cube.dimension)
        filter.cubeData = cube.data
        guard let filtered = filter.outputImage else { return nil }
        context.render(filtered, to: output, bounds: image.extent, colorSpace: nil)
        CVBufferSetAttachment(output, kCVImageBufferCGColorSpaceKey, Self.displayColorSpace, .shouldPropagate)
        return output
    }
}
