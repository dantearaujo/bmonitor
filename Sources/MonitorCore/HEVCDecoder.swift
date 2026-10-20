import CoreMedia
import Foundation
import VideoToolbox

/// Decodifica HEVC em Annex B com VideoToolbox, por hardware e sem fila.
/// O VideoToolbox entrega os quadros em ordem de decodificação; o stream do iPhone não tem
/// B-frames, então essa ordem já é a de exibição e nada precisa ser segurado.
public final class HEVCDecoder {
    public var onFrame: ((CVPixelBuffer) -> Void)?

    private var vps: Data?
    private var sps: Data?
    private var pps: Data?
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?

    public init() {}

    deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
    }

    /// Decodifica um quadro de forma síncrona: `onFrame` roda antes do retorno.
    public func decode(_ unit: VideoAccessUnit) {
        var sample = Data()
        var parametersChanged = false
        for nal in Self.nalUnits(unit.data) {
            guard let header = nal.first else { continue }
            switch (header >> 1) & 0x3F {
            case 32: if vps != nal { vps = nal; parametersChanged = true }
            case 33: if sps != nal { sps = nal; parametersChanged = true }
            case 34: if pps != nal { pps = nal; parametersChanged = true }
            case 35: continue  // delimitador de access unit
            default:
                var length = UInt32(nal.count).bigEndian
                withUnsafeBytes(of: &length) { sample.append(contentsOf: $0) }
                sample.append(nal)
            }
        }
        if parametersChanged { rebuildSession() }
        guard let session, let format, !sample.isEmpty else { return }

        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: sample.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: sample.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard let block else { return }
        sample.withUnsafeBytes {
            _ = CMBlockBufferReplaceDataBytes(
                with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: sample.count)
        }

        let pts = unit.pts.map { CMTime(value: $0, timescale: 90_000) } ?? .invalid
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var size = sample.count
        var buffer: CMSampleBuffer?
        CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &buffer)
        guard let buffer else { return }

        VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: buffer, flags: [._1xRealTimePlayback], infoFlagsOut: nil
        ) { [weak self] status, _, image, _, _ in
            guard status == noErr, let image else { return }
            self?.onFrame?(image)
        }
    }

    private func rebuildSession() {
        guard let vps, let sps, let pps else { return }
        var newFormat: CMFormatDescription?
        let status = vps.withUnsafeBytes { v in
            sps.withUnsafeBytes { s in
                pps.withUnsafeBytes { p in
                    let pointers = [v, s, p].map { $0.bindMemory(to: UInt8.self).baseAddress! }
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault, parameterSetCount: 3,
                        parameterSetPointers: pointers, parameterSetSizes: [v.count, s.count, p.count],
                        nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &newFormat)
                }
            }
        }
        guard status == noErr, let newFormat else { return }

        if let session, VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: newFormat) {
            format = newFormat
            return
        }
        if let session { VTDecompressionSessionInvalidate(session) }

        let spec = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true] as CFDictionary
        let attributes = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ] as CFDictionary
        var newSession: VTDecompressionSession?
        VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: newFormat, decoderSpecification: spec,
            imageBufferAttributes: attributes, outputCallback: nil, decompressionSessionOut: &newSession)
        guard let newSession else { return }
        VTSessionSetProperty(newSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = newSession
        format = newFormat
    }

    /// Separa um buffer Annex B em NAL units, sem os códigos de início.
    static func nalUnits(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var payloadStarts: [Int] = []
        var codeStarts: [Int] = []
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                codeStarts.append(i > 0 && bytes[i - 1] == 0 ? i - 1 : i)
                payloadStarts.append(i + 3)
                i += 3
            } else {
                i += 1
            }
        }
        return payloadStarts.indices.map { k in
            let end = k + 1 < payloadStarts.count ? codeStarts[k + 1] : bytes.count
            return Data(bytes[payloadStarts[k]..<end])
        }
    }
}
