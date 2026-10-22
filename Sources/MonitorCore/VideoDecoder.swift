import CoreMedia
import Foundation
import VideoToolbox

/// Decodifica HEVC ou H.264 em Annex B com VideoToolbox, por hardware e sem fila. O iPhone
/// transmite em HEVC, menos quando grava em H.264: aí o stream também vem em H.264.
/// O VideoToolbox entrega os quadros em ordem de decodificação; o stream do iPhone não tem
/// B-frames, então essa ordem já é a de exibição e nada precisa ser segurado.
public final class VideoDecoder {
    public var onFrame: ((CVPixelBuffer) -> Void)?
    /// O quadro ainda codificado e se ele é quadro-chave, depois de ir para a tela.
    public var onSample: ((CMSampleBuffer, Bool) -> Void)?

    private var h264 = false
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
        if unit.isH264 != h264 {
            h264 = unit.isH264
            vps = nil; sps = nil; pps = nil; format = nil
        }
        var sample = Data()
        var parametersChanged = false
        var keyframe = false
        for nal in Self.nalUnits(unit.data) {
            guard let header = nal.first else { continue }
            let kind = h264 ? Self.h264Kind(header) : Self.hevcKind(header)
            switch kind {
            case .vps: if vps != nal { vps = nal; parametersChanged = true }
            case .sps: if sps != nal { sps = nal; parametersChanged = true }
            case .pps: if pps != nal { pps = nal; parametersChanged = true }
            case .delimiter: continue
            case .keyframe, .other:
                if kind == .keyframe { keyframe = true }
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
        onSample?(buffer, keyframe)
    }

    private enum NALKind { case vps, sps, pps, delimiter, keyframe, other }

    private static func hevcKind(_ header: UInt8) -> NALKind {
        switch (header >> 1) & 0x3F {
        case 32: .vps
        case 33: .sps
        case 34: .pps
        case 35: .delimiter
        case 16...21: .keyframe  // IRAP: IDR, CRA, BLA
        default: .other
        }
    }

    private static func h264Kind(_ header: UInt8) -> NALKind {
        switch header & 0x1F {
        case 7: .sps
        case 8: .pps
        case 9: .delimiter
        case 5: .keyframe  // IDR
        default: .other
        }
    }

    private func rebuildSession() {
        guard let sps, let pps, h264 || vps != nil else { return }
        let sets = h264 ? [sps, pps] : [vps!, sps, pps]
        var newFormat: CMFormatDescription?
        let status = Self.withPointers(sets) { pointers, sizes in
            h264
                ? CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &newFormat)
                : CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &newFormat)
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

    /// Ponteiros estáveis para os conjuntos de parâmetros enquanto `body` roda.
    private static func withPointers(
        _ sets: [Data], _ body: ([UnsafePointer<UInt8>], [Int]) -> OSStatus
    ) -> OSStatus {
        let buffers = sets.map { [UInt8]($0) }
        let copies = buffers.map { bytes -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: bytes.count)
            p.initialize(from: bytes, count: bytes.count)
            return p
        }
        defer { copies.forEach { $0.deallocate() } }
        return body(copies.map { UnsafePointer($0) }, buffers.map(\.count))
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
