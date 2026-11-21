import AVFoundation

public struct MacMicrophone: Identifiable, Equatable {
    public let id: String
    public let name: String

    public static func available() -> [Self] {
        devices().map { Self(id: $0.uniqueID, name: $0.localizedName) }
    }

    fileprivate static func devices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices
    }
}

final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "bmonitor.microphone", qos: .userInitiated)
    var onSample: ((MicrophoneCapture, CMSampleBuffer, CMTime, AVAudioPCMBuffer) -> Void)?

    func start(id: String) async throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        let allowed: Bool
        if status == .notDetermined {
            allowed = await AVCaptureDevice.requestAccess(for: .audio)
        } else {
            allowed = status == .authorized
        }
        guard allowed else { throw CocoaError(.fileReadNoPermission) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                continuation.resume(with: Result { try configure(id: id) })
            }
        }
    }

    private func configure(id: String) throws {
        guard let device = MacMicrophone.devices().first(where: { $0.uniqueID == id }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 48_000,
        ]
        guard session.canAddInput(input) else { throw CocoaError(.featureUnsupported) }
        session.addInput(input)
        guard session.canAddOutput(output) else { throw CocoaError(.featureUnsupported) }
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: queue)
        session.startRunning()
        guard session.isRunning else { throw CocoaError(.featureUnsupported) }
    }

    func stop() {
        queue.async { [self] in session.stopRunning() }
    }

    func captureOutput(
        _ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection
    ) {
        guard sample.numSamples > 0, let format = sample.formatDescription,
            let buffer = AVAudioPCMBuffer(
                pcmFormat: AVAudioFormat(cmAudioFormatDescription: format),
                frameCapacity: AVAudioFrameCount(sample.numSamples))
        else { return }
        buffer.frameLength = buffer.frameCapacity
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample, at: 0, frameCount: Int32(buffer.frameLength), into: buffer.mutableAudioBufferList
        ) == noErr else { return }
        let pts = session.synchronizationClock?.convertTime(sample.presentationTimeStamp, to: CMClock.hostTimeClock)
        onSample?(self, sample, pts ?? CMClock.hostTimeClock.time, buffer)
    }
}
