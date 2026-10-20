import AVFoundation
import AppKit
import SwiftUI

/// Hospeda a `AVSampleBufferDisplayLayer` que a `StreamSession` alimenta, girada em quartos
/// de volta. O enquadramento (`resizeAspect`) fica com a própria camada.
struct VideoLayerView: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    let quarterTurns: Int

    func makeNSView(context: Context) -> HostView {
        let view = HostView()
        view.videoLayer = layer
        view.quarterTurns = quarterTurns
        return view
    }

    func updateNSView(_ view: HostView, context: Context) {
        view.quarterTurns = quarterTurns
        view.needsLayout = true
    }

    final class HostView: NSView {
        var quarterTurns = 0
        var videoLayer: AVSampleBufferDisplayLayer? {
            didSet {
                guard let videoLayer else { return }
                videoLayer.videoGravity = .resizeAspect
                layer?.addSublayer(videoLayer)
            }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            guard let videoLayer else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let turns = ((quarterTurns % 4) + 4) % 4
            let size = turns % 2 == 1 ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
            videoLayer.bounds = CGRect(origin: .zero, size: size)
            videoLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
            videoLayer.setAffineTransform(CGAffineTransform(rotationAngle: -CGFloat(turns) * .pi / 2))
            CATransaction.commit()
        }
    }
}

enum VideoEnqueue {
    /// Põe o quadro decodificado na camada para exibição imediata, sem relógio nem fila.
    static func enqueue(_ image: CVPixelBuffer, into layer: AVSampleBufferDisplayLayer) {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image, formatDescriptionOut: &format)
        guard let format else { return }
        var timing = CMSampleTimingInfo(
            duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: image, formatDescription: format, sampleTiming: &timing,
            sampleBufferOut: &sample)
        guard let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
            CFArrayGetCount(attachments) > 0
        {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sample)
    }
}
