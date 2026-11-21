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
private func encodeADTS(seconds: Double, signal: ((Int) -> Float)? = nil) throws -> [AudioAccessUnit] {
    let pcm = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
    var description = AudioStreamBasicDescription(
        mSampleRate: 48_000, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0, mBytesPerPacket: 0,
        mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
    let aac = try #require(AVAudioFormat(streamDescription: &description))
    let converter = try #require(AVAudioConverter(from: pcm, to: aac))

    let input = try #require(AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(48_000 * seconds)))
    input.frameLength = input.frameCapacity
    for c in 0..<2 {
        for n in 0..<Int(input.frameLength) { input.floatChannelData![c][n] = signal?(n) ?? 0.2 * sin(Float(n) * 0.06) }
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


@Test(arguments: TakeRecorder.MicrophoneMode.allCases)
func copyRecordsSelectedMicrophoneMode(mode: TakeRecorder.MicrophoneMode) async throws {
    let url = temporaryMovie()
    let sidecar = TakeRecorder.microphoneURL(url)
    defer {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: sidecar)
    }
    let recorder = TakeRecorder(tail: 0)
    let delay = CMTime(value: 300, timescale: 1000)
    try #require(recorder.configureMicrophone(mode, delay: delay))
    let phoneAudio = try encodeADTS(seconds: 2)
    recorder.appendAudio(try #require(phoneAudio.first))
    recorder.begin(url: url, quarterTurns: 0)
    #expect(!recorder.configureMicrophone(nil, delay: .zero))
    let pcm = try microphoneSample()
    let base = CMTime(seconds: 100, preferredTimescale: 48_000)
    for (index, frame) in try encodeHEVC(frames: 60, keyframeEvery: 30).enumerated() {
        let time = frame.sample.presentationTimeStamp
        recorder.appendVideo(frame.sample, keyframe: frame.keyframe, hostTime: base + time)
        if index < 50 {
            recorder.appendMicrophone(pcm, hostTime: base + time)
        }
        for unit in phoneAudio where unit.pts.map({ $0 / 3000 == Int64(index) }) == true {
            recorder.appendAudio(unit)
        }
    }
    recorder.endBlocking()

    let movie = AVURLAsset(url: url)
    #expect(try await movie.loadTracks(withMediaType: .video).count == 1)
    let tracks = try await movie.loadTracks(withMediaType: .audio)
    #expect(tracks.count == (mode == .both ? 2 : 1))
    // O microfone fica sempre ao lado: é dele que sai a junção com o original do iPhone.
    #expect(FileManager.default.fileExists(atPath: sidecar.path))
    let audioAsset = mode == .separate ? AVURLAsset(url: sidecar) : movie
    let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
    var microphone: AVAssetTrack?
    for track in audioTracks {
        let format = try #require(try await track.load(.formatDescriptions).first)
        if CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee.mChannelsPerFrame == 1 {
            microphone = track
        }
    }
    let mic = try #require(microphone)
    let segments = try await mic.load(.segments)
    let media = try #require(segments.first { !$0.isEmpty })
    #expect(abs(media.timeMapping.target.start.seconds - 0.3) < 0.04)
    #expect(try await mic.load(.timeRange).end.seconds > 1.7)
}

@Test func microphoneSyncCompensatesForClockDriftAndResetsWithVideo() throws {
    var sync = MicrophoneSync()
    func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 1_000_000) }
    let rate = 1.0004
    let delay = time(0.3)
    for frame in 0...18_000 {
        let elapsed = Double(frame) / 30
        let jitter = Double(frame % 9) * 0.003
        _ = sync.observe(video: time(elapsed * rate), arrival: time(100 + elapsed + jitter))
    }
    let pts = try #require(sync.presentationTime(for: time(700), delay: delay))
    #expect(abs(pts.seconds - (600 * rate + 0.3)) < 0.04)
    let resetDetected = sync.observe(video: .zero, arrival: time(800))
    #expect(resetDetected)
    let reset = try #require(sync.presentationTime(for: time(800), delay: delay))
    #expect(abs(reset.seconds - 0.3) < 0.001)
}

private func microphoneSample() throws -> CMSampleBuffer {
    let frames = 1600
    let bytes = frames * MemoryLayout<Int16>.size
    var asbd = AudioStreamBasicDescription(
        mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
        mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
    var description: CMAudioFormatDescription?
    try #require(CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
        magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description) == noErr)
    let format = try #require(description)
    var storage: CMBlockBuffer?
    try #require(CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
        blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: bytes,
        flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &storage) == noErr)
    let block = try #require(storage)
    try #require(CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) == noErr)
    var sample: CMSampleBuffer?
    try #require(CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
        sampleCount: frames, presentationTimeStamp: .zero, packetDescriptions: nil,
        sampleBufferOut: &sample) == noErr)
    return try #require(sample)
}


// MARK: - Sincronia pelo som do iPhone

/// Ruído com rajadas, como fala: periódico daria vários picos iguais.
private func speechLikeNoise(_ n: Int, seed: UInt64 = 7) -> Float {
    var x = (UInt64(n) &+ seed) &* 0x9E37_79B9_7F4A_7C15
    x ^= x >> 31
    x = x &* 0xBF58_476D_1CE4_E5B9
    x ^= x >> 29
    let white = Float(x % 20_000) / 10_000 - 1
    let envelope: Float = (n / 4_000) % 3 == 0 ? 0.05 : 0.6
    return white * envelope * 0.4
}

@Test(arguments: [0.237, -0.412, 1.5])
func alignmentFindsTheOffsetBetweenTwoMicrophones(offset: Double) throws {
    let rate = 8_000.0
    let reference = (0..<Int(rate * 6)).map { speechLikeNoise($0) }
    // Outro microfone: outro timbre (média móvel), ruído próprio e ganho diferente.
    let shift = Int(offset * rate)
    let candidate = (0..<Int(rate * 5)).map { m -> Float in
        let n = m + shift + Int(rate / 2)
        guard n >= 2, n < reference.count else { return 0 }
        let colored = (reference[n] + reference[n - 1] + reference[n - 2]) / 3
        return 0.5 * colored + 0.05 * speechLikeNoise(m, seed: 99)
    }
    let match = try #require(AudioAlignment.match(reference: reference, candidate: candidate, sampleRate: rate))
    #expect(abs(match.offset - (offset + 0.5)) < 0.001)
    #expect(match.confidence > AudioAlignment.minimumConfidence)
}

@Test func alignmentReportsLowConfidenceForUnrelatedSound() throws {
    let rate = 8_000.0
    let a = (0..<Int(rate * 4)).map { speechLikeNoise($0, seed: 1) }
    let b = (0..<Int(rate * 4)).map { speechLikeNoise($0, seed: 123_456) }
    let match = AudioAlignment.match(reference: a, candidate: b, sampleRate: rate)
    #expect((match?.confidence ?? 0) < AudioAlignment.minimumConfidence)
}

/// O relógio põe o microfone 120 ms fora; o som do iPhone no take corrige.
@Test func takeSyncsTheMacMicrophoneByThePhoneAudio() async throws {
    let url = temporaryMovie()
    let sidecar = TakeRecorder.microphoneURL(url)
    defer {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: sidecar)
    }
    let recorder = TakeRecorder(tail: 0)
    try #require(recorder.configureMicrophone(.both, delay: CMTime(value: 300, timescale: 1000)))
    let phoneAudio = try encodeADTS(seconds: 3) { speechLikeNoise($0) }
    recorder.appendAudio(try #require(phoneAudio.first))
    recorder.begin(url: url, quarterTurns: 0)
    let base = CMTime(seconds: 100, preferredTimescale: 48_000)
    let error = 0.12
    for (index, frame) in try encodeHEVC(frames: 75, keyframeEvery: 30).enumerated() {
        let time = frame.sample.presentationTimeStamp
        recorder.appendVideo(frame.sample, keyframe: frame.keyframe, hostTime: base + time)
        // O bloco cai em time + 0,3 s, mas traz o som de 120 ms depois.
        let first = Int(((time.seconds + 0.3 + error) * 48_000).rounded())
        recorder.appendMicrophone(try pcmSample((0..<1600).map { speechLikeNoise(first + $0) * 0.7 }), hostTime: base + time)
        for unit in phoneAudio where unit.pts.map({ $0 / 3000 == Int64(index) }) == true { recorder.appendAudio(unit) }
    }
    recorder.endBlocking(timeout: 10)

    let movie = AVURLAsset(url: url)
    let tracks = try await movie.loadTracks(withMediaType: .audio)
    #expect(tracks.count == 2)
    var phone: AVAssetTrack?, mac: AVAssetTrack?
    for track in tracks {
        if try await track.load(.isEnabled) { mac = track } else { phone = track }
    }
    let reference = try await MacAudioMerger.samples(of: movie, track: try #require(phone))
    let microphone = try await MacAudioMerger.samples(of: movie, track: try #require(mac))
    // Lado a lado no arquivo: o som do Mac agora bate com o do iPhone.
    let match = try #require(AudioAlignment.match(
        reference: reference, candidate: microphone, sampleRate: 8_000, expected: 0, window: 0.5))
    #expect(abs(match.offset) < 0.003)
}

/// O clipe original do iPhone, com timecode e tudo, ganha o som do Mac sem recodificar.
@Test func mergesAnOriginalClipWithTheMacMicrophone() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bmonitor-merge-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let original = folder.appendingPathComponent("A001_C001.mov")
    let microphone = folder.appendingPathComponent("A001_C001 bmonitor - Mac Mic.mov")
    let output = folder.appendingPathComponent("A001_C001 Mac.mov")

    // Original: 2,5 s de vídeo e o som do iPhone.
    let writer = try AVAssetWriter(outputURL: original, fileType: .mov)
    let frames = try encodeHEVC(frames: 75, keyframeEvery: 30)
    let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: frames[0].sample.formatDescription)
    let phoneInput = AVAssetWriterInput(mediaType: .audio, outputSettings: pcmSettings(bits: 16))
    // Tempo real: sem isso o writer segura uma trilha esperando a outra e o teste trava.
    videoInput.expectsMediaDataInRealTime = true
    phoneInput.expectsMediaDataInRealTime = true
    writer.add(videoInput)
    writer.add(phoneInput)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    for frame in frames {
        TakeRecorder.markSync(frame.sample, keyframe: frame.keyframe)
        while !videoInput.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
        videoInput.append(frame.sample)
    }
    for block in 0..<75 {
        let pcm = try pcmSample((0..<1600).map { speechLikeNoise(block * 1600 + $0) }, pts: CMTime(value: Int64(block * 1600), timescale: 48_000))
        while !phoneInput.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
        phoneInput.append(pcm)
    }
    videoInput.markAsFinished()
    phoneInput.markAsFinished()
    await writer.finishWriting()

    // Mac: começou 0,8 s antes do clipe e ouve a sala com outro ganho.
    let early = 0.8
    let micWriter = try AVAssetWriter(outputURL: microphone, fileType: .mov)
    let micInput = AVAssetWriterInput(mediaType: .audio, outputSettings: pcmSettings(bits: 24))
    micInput.expectsMediaDataInRealTime = true
    micWriter.add(micInput)
    micWriter.startWriting()
    micWriter.startSession(atSourceTime: .zero)
    for block in 0..<100 {
        let first = block * 1600 - Int(early * 48_000)
        let pcm = try pcmSample((0..<1600).map { first + $0 < 0 ? 0 : speechLikeNoise(first + $0) * 0.5 }, pts: CMTime(value: Int64(block * 1600), timescale: 48_000))
        while !micInput.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
        micInput.append(pcm)
    }
    micInput.markAsFinished()
    await micWriter.finishWriting()

    let result = try await MacAudioMerger.merge(video: original, microphone: microphone, output: output, keepPhoneAudio: false)
    #expect(result.synced)
    #expect(abs(result.offset + early) < 0.002)

    let merged = AVURLAsset(url: output)
    #expect(try await merged.loadTracks(withMediaType: .video).count == 1)
    let audio = try await merged.loadTracks(withMediaType: .audio)
    #expect(audio.count == 1)
    let format = try #require(try await audio[0].load(.formatDescriptions).first)
    #expect(CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee.mBitsPerChannel == 24)
    #expect(abs(try await merged.load(.duration).seconds - 2.5) < 0.05)
    // A imagem não foi recodificada: mesmo codec e mesmo número de quadros.
    let video = try #require(try await merged.loadTracks(withMediaType: .video).first)
    let videoFormat = try #require(try await video.load(.formatDescriptions).first)
    #expect(CMFormatDescriptionGetMediaSubType(videoFormat) == kCMVideoCodecType_HEVC)
}

private func pcmSettings(bits: Int) -> [String: Any] {
    [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: bits, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]
}

/// Bloco mono de 48 kHz em 16 bits com as amostras dadas.
private func pcmSample(_ values: [Float], pts: CMTime = .zero) throws -> CMSampleBuffer {
    let ints = values.map { Int16(max(-1, min(1, $0)) * 32_767) }
    let bytes = ints.count * MemoryLayout<Int16>.size
    var asbd = AudioStreamBasicDescription(
        mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
        mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
    var description: CMAudioFormatDescription?
    try #require(CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
        magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description) == noErr)
    var storage: CMBlockBuffer?
    try #require(CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
        blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: bytes,
        flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &storage) == noErr)
    let block = try #require(storage)
    try ints.withUnsafeBytes {
        try #require(CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) == noErr)
    }
    var sample: CMSampleBuffer?
    try #require(CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: try #require(description),
        sampleCount: values.count, presentationTimeStamp: pts, packetDescriptions: nil,
        sampleBufferOut: &sample) == noErr)
    return try #require(sample)
}

// MARK: - Linha do tempo da cópia

private func seconds(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 90_000) }

@Test func timelineKeepsTheIPhonePTSWhenTheStreamIsWhole() {
    var timeline = StreamTimeline()
    var generator = SystemRandomNumberGenerator()
    var host = 1000.0
    for i in 0..<900 {
        let pts = 3600 + Double(i) / 30
        // Tremor de até 60 ms e, no meio, um engasgo de meio segundo que termina numa rajada.
        let stall = (300..<315).contains(i) ? 0.5 - Double(i - 300) / 30 : 0
        let arrival = host + Double(i) / 30 + Double.random(in: 0...0.06, using: &generator) + max(stall, 0)
        let out = timeline.map(stream: seconds(pts), host: seconds(arrival))
        #expect(abs(out.seconds - pts) < 0.0001, "quadro \(i)")
    }
}

@Test func timelineFollowsTheMacClockWhenTheIPhoneSendsLess() {
    // iPhone 14 a 60 fps gravando: 29 quadros por segundo, PTS de 1/60 em 1/60.
    var timeline = StreamTimeline()
    var previous = -Double.infinity
    var first = 0.0
    var last = 0.0
    for i in 0..<(29 * 60) {
        let out = timeline.map(stream: seconds(3600 + Double(i) / 60), host: seconds(1000 + Double(i) / 29)).seconds
        #expect(out > previous)
        previous = out
        if i == 0 { first = out }
        last = out
    }
    // 60 s de verdade; com o PTS como veio seriam 29 s.
    #expect(abs((last - first) - 60) < 0.5)
    #expect(timeline.streamSpan / timeline.outSpan < 0.55)
}

@Test func timelineRestartsWithTheStream() {
    var timeline = StreamTimeline()
    for i in 0..<120 { _ = timeline.map(stream: seconds(3600 + Double(i) / 60), host: seconds(1000 + Double(i) / 30)) }
    let restarted = timeline.map(stream: seconds(10), host: seconds(1010))
    #expect(restarted.seconds == 10)
    #expect(timeline.position(of: seconds(10.5))?.seconds == 10.5)
}

@Test func phoneAudioKeepsItsPlaceAcrossGaps() async throws {
    let url = temporaryMovie()
    defer { try? FileManager.default.removeItem(at: url) }
    let recorder = TakeRecorder(tail: 0)
    let audio = try encodeADTS(seconds: 2)
    recorder.appendAudio(audio[0])
    recorder.begin(url: url, quarterTurns: 0)
    let base = CMTime(seconds: 100, preferredTimescale: 90_000)
    var a = 1
    for frame in try encodeHEVC(frames: 60, keyframeEvery: 30) {
        let time = frame.sample.presentationTimeStamp
        while a < audio.count, CMTime(value: audio[a].pts!, timescale: 90_000) <= time {
            // 0,4 s de som que o iPhone não mandou.
            let at = Double(audio[a].pts!) / 90_000
            if !(0.8..<1.2).contains(at) { recorder.appendAudio(audio[a]) }
            a += 1
        }
        recorder.appendVideo(frame.sample, keyframe: frame.keyframe, hostTime: base + time)
    }
    recorder.endBlocking()

    let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).first)
    // Sem o silêncio no buraco, o som encolheria para ~1,5 s.
    #expect(try await track.load(.timeRange).duration.seconds > 1.85)
}

@Test func silentAACFrameEncodes() {
    #expect((TakeRecorder.silentAAC(sampleRate: 48_000, channels: 2)?.count ?? 0) > 0)
    #expect((TakeRecorder.silentAAC(sampleRate: 48_000, channels: 1)?.count ?? 0) > 0)
}

@Test func halfSpeedStreamRecordsAtRealSpeedWithPhoneAudioInPlace() async throws {
    // Como o iPhone 14 a 60 fps gravando: o PTS de imagem e som anda metade do relógio.
    let url = temporaryMovie()
    defer { try? FileManager.default.removeItem(at: url) }
    let recorder = TakeRecorder(tail: 0)
    let audio = try encodeADTS(seconds: 4)
    let video = try encodeHEVC(frames: 120, keyframeEvery: 30)
    recorder.appendAudio(audio[0])
    recorder.begin(url: url, quarterTurns: 0)
    let base = CMTime(seconds: 100, preferredTimescale: 90_000)
    var a = 1
    for frame in video {
        let time = frame.sample.presentationTimeStamp
        while a < audio.count, CMTime(value: audio[a].pts!, timescale: 90_000) <= time {
            recorder.appendAudio(audio[a])
            a += 1
        }
        recorder.appendVideo(frame.sample, keyframe: frame.keyframe, hostTime: base + CMTimeMultiply(time, multiplier: 2))
    }
    recorder.endBlocking()

    let movie = AVURLAsset(url: url)
    let picture = try #require(try await movie.loadTracks(withMediaType: .video).first)
    let sound = try #require(try await movie.loadTracks(withMediaType: .audio).first)
    let videoSeconds = try await picture.load(.timeRange).duration.seconds
    let audioSeconds = try await sound.load(.timeRange).duration.seconds
    // 4 s de PTS chegando em 8 s: o arquivo tem que durar perto de 8 s, imagem e som juntos.
    #expect(videoSeconds > 6.5, "vídeo \(videoSeconds)")
    #expect(abs(audioSeconds - videoSeconds) < 0.3, "som \(audioSeconds), vídeo \(videoSeconds)")
}
