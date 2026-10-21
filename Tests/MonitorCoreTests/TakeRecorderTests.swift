import AVFoundation
import Foundation
import Testing
import VideoToolbox

@testable import MonitorCore

// Sem o stream real no repo, os testes geram HEVC e AAC no próprio Mac, no formato que o
// decodificador entrega ao gravador: HEVC com NAL de 4 bytes e PES de áudio com ADTS.

@Test func copyStartsAtTheKeyframeBeforeRec() async throws {
    let url = temporaryMovie()
    let recorder = TakeRecorder(tail: 0)
    let video = try encodeHEVC(frames: 75, keyframeEvery: 30)
    for (i, frame) in video.enumerated() {
        if i == 40 { recorder.begin(url: url, quarterTurns: 0) }
        recorder.appendVideo(frame.sample, keyframe: frame.keyframe)
    }
    recorder.endBlocking()

    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let range = try await track.load(.timeRange)
    // Quadros 30 a 74: o arquivo começa no quadro-chave 30, antes do REC no quadro 40.
    // Começando no REC seriam 35 quadros.
    #expect(range.start.seconds == 0)
    #expect(abs(range.duration.seconds - 45.0 / 30) < 0.05)
    let format = try #require(try await track.load(.formatDescriptions).first)
    #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC)
}

@Test func copyKeepsTheAudio() async throws {
    let url = temporaryMovie()
    let recorder = TakeRecorder(tail: 0)
    let video = try encodeHEVC(frames: 60, keyframeEvery: 30)
    let audio = try encodeADTS(seconds: 2)
    // No stream o áudio já está chegando quando o REC vem: é dele que sai o formato da trilha.
    recorder.appendAudio(audio[0])
    recorder.begin(url: url, quarterTurns: 0)
    // Intercala como no stream: um PES de áudio a cada ~21 ms, um quadro a cada 33 ms.
    var a = 1
    for frame in video {
        while a < audio.count, CMTime(value: audio[a].pts!, timescale: 90_000) <= frame.sample.presentationTimeStamp {
            recorder.appendAudio(audio[a])
            a += 1
        }
        recorder.appendVideo(frame.sample, keyframe: frame.keyframe)
    }
    recorder.endBlocking()

    let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio)
    let track = try #require(tracks.first)
    let format = try #require(try await track.load(.formatDescriptions).first)
    #expect(CMFormatDescriptionGetMediaSubType(format) == kAudioFormatMPEG4AAC)
    #expect(try await track.load(.timeRange).duration.seconds > 1.5)
}

@Test func streamRestartContinuesInANumberedFile() async throws {
    let url = temporaryMovie()
    let recorder = TakeRecorder(tail: 0)
    let video = try encodeHEVC(frames: 60, keyframeEvery: 30)
    recorder.begin(url: url, quarterTurns: 0)
    for frame in video { recorder.appendVideo(frame.sample, keyframe: frame.keyframe) }
    // O stream recomeça e o relógio volta para o início.
    for frame in try encodeHEVC(frames: 60, keyframeEvery: 30) { recorder.appendVideo(frame.sample, keyframe: frame.keyframe) }
    recorder.endBlocking()

    let second = TakeRecorder.partURL(url, 2)
    #expect(second.lastPathComponent == url.deletingPathExtension().lastPathComponent + " (2).mov")
    #expect(try await AVURLAsset(url: url).load(.duration).seconds > 1.9)
    #expect(try await AVURLAsset(url: second).load(.duration).seconds > 1.9)
}

@Test func portraitMonitorRotatesTheTrack() {
    let size = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    for turns in 0..<4 {
        let rotated = size.applying(TakeRecorder.transform(quarterTurns: turns, width: 1920, height: 1080))
        #expect(rotated.origin == .zero)
        #expect(rotated.size == (turns % 2 == 0 ? size.size : CGSize(width: 1080, height: 1920)))
    }
    // Uma volta para a direita: o canto de cima à esquerda vai para cima à direita.
    let corner = CGPoint.zero.applying(TakeRecorder.transform(quarterTurns: 1, width: 1920, height: 1080))
    #expect(corner == CGPoint(x: 1080, y: 0))
}

// MARK: - Mídia sintética

private func temporaryMovie() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("bmonitor-test-\(UUID().uuidString).mov")
}

private struct EncodedFrame: @unchecked Sendable {
    var sample: CMSampleBuffer
    var keyframe: Bool
}

/// Quadros HEVC de 320x180 a 30 fps com PTS em 90 kHz, como chegam do iPhone.
private func encodeHEVC(frames: Int, keyframeEvery: Int) throws -> [EncodedFrame] {
    var session: VTCompressionSession?
    let status = VTCompressionSessionCreate(
        allocator: nil, width: 320, height: 180, codecType: kCMVideoCodecType_HEVC, encoderSpecification: nil,
        imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
        compressionSessionOut: &session)
    let encoder = try #require(session, "HEVC encoder unavailable: \(status)")
    defer { VTCompressionSessionInvalidate(encoder) }
    VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
    VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: keyframeEvery as CFNumber)

    var output: [EncodedFrame] = []
    let lock = NSLock()
    for i in 0..<frames {
        var pixels: CVPixelBuffer?
        CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_32BGRA, nil, &pixels)
        let buffer = try #require(pixels)
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), Int32(i * 3 % 255), CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let pts = CMTime(value: Int64(i) * 3000, timescale: 90_000)
        let properties = i % keyframeEvery == 0 ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        VTCompressionSessionEncodeFrame(
            encoder, imageBuffer: buffer, presentationTimeStamp: pts, duration: .invalid, frameProperties: properties,
            infoFlagsOut: nil
        ) { _, _, sample in
            guard let sample else { return }
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
            let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
            lock.lock()
            output.append(EncodedFrame(sample: sample, keyframe: !notSync))
            lock.unlock()
        }
    }
    VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid)
    return output.sorted { $0.sample.presentationTimeStamp < $1.sample.presentationTimeStamp }
}

/// PES de áudio AAC-LC 48 kHz estéreo com ADTS, um quadro por PES, PTS em 90 kHz.
private func encodeADTS(seconds: Double) throws -> [AudioAccessUnit] {
    let pcm = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
    var description = AudioStreamBasicDescription(
        mSampleRate: 48_000, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0, mBytesPerPacket: 0,
        mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
    let aac = try #require(AVAudioFormat(streamDescription: &description))
    let converter = try #require(AVAudioConverter(from: pcm, to: aac))

    let input = try #require(AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(48_000 * seconds)))
    input.frameLength = input.frameCapacity
    for c in 0..<2 {
        for n in 0..<Int(input.frameLength) { input.floatChannelData![c][n] = 0.2 * sin(Float(n) * 0.06) }
    }
    var units: [AudioAccessUnit] = []
    var fed = false
    while true {
        let out = AVAudioCompressedBuffer(format: aac, packetCapacity: 32, maximumPacketSize: converter.maximumOutputPacketSize)
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .endOfStream
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return input
        }
        for p in 0..<Int(out.packetCount) {
            let packet = out.packetDescriptions![p]
            let payload = Data(bytes: out.data + Int(packet.mStartOffset), count: Int(packet.mDataByteSize))
            let length = payload.count + 7
            // ADTS sem CRC: AAC-LC (perfil 1), 48 kHz (índice 3), 2 canais.
            let header: [UInt8] = [
                0xFF, 0xF1, 1 << 6 | 3 << 2, 2 << 6 | UInt8(length >> 11), UInt8((length >> 3) & 0xFF),
                UInt8((length & 7) << 5) | 0x1F, 0xFC,
            ]
            let pts = Int64(units.count) * 1024 * 90_000 / 48_000
            units.append(AudioAccessUnit(data: Data(header) + payload, pts: pts))
        }
        if status == .endOfStream || status == .error || out.packetCount == 0 { break }
    }
    return units
}

