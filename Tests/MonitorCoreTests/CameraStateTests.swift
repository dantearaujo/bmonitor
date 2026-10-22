import Foundation
import Testing

@testable import MonitorCore

/// Mensagens reais do WebSocket do iPhone (20/10), gravadas em `Fixtures/events.jsonl`.
private func recordedState() throws -> CameraState {
    let url = try #require(Bundle.module.url(forResource: "events", withExtension: "jsonl", subdirectory: "Fixtures"))
    let state = CameraState()
    for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
        for (property, value) in CameraEvents.changes(in: Data(line.utf8)) {
            state.apply(property: property, value: value)
        }
    }
    return state
}

@Test func appliesRecordedSnapshot() throws {
    let state = try recordedState()
    #expect(state.recording == false)
    #expect(state.clipName == "A001_10201031_C001")
    #expect(state.iso == 200)
    #expect(state.shutter == .speed(60))
    #expect(state.whiteBalance == 5600)
    #expect(state.tint == 10)
    #expect(state.lens == "2×")
    #expect(state.remainingRecordTime == 572)
    #expect(state.audioInputs[0] == "iPhone Microphone")
    #expect(state.videoFormat == "3840x2160p30")
    #expect(state.frameRate == 30)
    #expect(state.videoSize == CGSize(width: 3840, height: 2160))
}

@Test func timecodeHoldsWhileStopped() throws {
    let state = try recordedState()
    let later = Date().addingTimeInterval(5)
    #expect(state.timecode(at: later) == "00:00:07:09")
}

@Test func timecodeRunsWhileRecording() {
    let state = CameraState()
    let start = Date(timeIntervalSince1970: 1000)
    state.apply(property: "/system/videoFormat", value: ["frameRate": "30", "width": 3840, "height": 2160, "name": "3840x2160p30"], at: start)
    state.apply(property: "/transports/0/record", value: ["recording": true, "clipName": "A001_C002"], at: start)
    state.apply(property: "/transports/0/timecode", value: ["display": "10:31:59:20"], at: start)
    #expect(state.timecode(at: start.addingTimeInterval(1)) == "10:32:00:20")
    #expect(state.timecode(at: start.addingTimeInterval(0.5)) == "10:32:00:05")
}

@Test func remainingTimeLevels() {
    let state = CameraState()
    #expect(state.remainingLevel == .normal)
    state.apply(property: "/media/workingset", value: ["workingset": [["activeDisk": true, "remainingRecordTime": 599]]])
    #expect(state.remainingLevel == .warning)
    state.apply(property: "/media/workingset", value: ["workingset": [["activeDisk": true, "remainingRecordTime": 179]]])
    #expect(state.remainingLevel == .critical)
    state.apply(property: "/media/workingset", value: ["workingset": [["activeDisk": true, "remainingRecordTime": 600]]])
    #expect(state.remainingLevel == .normal)
}

@Test func shutterAngleFormat() {
    let state = CameraState()
    state.apply(property: "/video/shutter", value: ["shutterAngle": 180.0])
    #expect(state.shutter == .angle(180))
    #expect(state.shutter?.label == "180°")
    #expect(Shutter.speed(60).label == "1/60")
}

@Test func parsesControlRanges() {
    let state = CameraState()
    state.apply(property: "/video/supportedISOs", value: ["supportedISOs": [54, 64, 100, 200, 3456]])
    state.apply(
        property: "/video/supportedShutters",
        value: ["shutterSpeeds": [30, 50, 60], "shutterAngles": [360, 327.27272727272725, 180]])
    state.apply(property: "/video/flickerFreeShutters", value: ["shutterSpeeds": [50], "shutterAngles": [327.27272727272725]])
    state.apply(property: "/video/whiteBalance/description", value: ["whiteBalance": ["min": 2500, "max": 10000]])
    state.apply(property: "/lens/zoom/description", value: ["focalLength": ["min": 48, "max": 360], "controllable": true])
    state.apply(property: "/lens/zoom", value: ["focalLength": 72, "normalised": 0.1])
    state.apply(property: "/lens/focus", value: ["normalised": 0.65])
    state.apply(property: "/video/autoExposure", value: ["mode": "Continuous"])
    state.apply(property: "/audio/channel/0/supportedInputs", value: ["items": [["input": "None", "available": true], ["input": "iPhone Microphone", "available": true], ["input": "DJI Mic", "available": false]]])
    state.apply(
        property: "/lens/cameras",
        value: ["cameras": [
            ["zoomFactor": "0.5x", "id": "Lens13mm", "facing": "back", "focalLength": 13, "isActive": false, "isAvailable": true, "index": 2],
            ["zoomFactor": "2x", "id": "LensWASecondary", "facing": "back", "focalLength": 48, "isActive": true, "isAvailable": true, "index": 4],
            ["zoomFactor": "0.5x", "id": "LensFront", "facing": "front", "focalLength": 19, "isActive": false, "isAvailable": true, "index": 1],
        ]])

    #expect(state.supportedISOs == [54, 64, 100, 200, 3456])
    #expect(state.shutterSpeeds == [30, 50, 60])
    #expect(state.shutterAngles.count == 3)
    #expect(state.isFlickerFree(.speed(50)))
    #expect(state.isFlickerFree(.angle(327.27272727272725)))
    #expect(!state.isFlickerFree(.speed(60)))
    #expect(state.whiteBalanceRange == 2500...10000)
    #expect(state.zoomRange == 48...360)
    #expect(state.zoomFocalLength == 72)
    #expect(state.zoomNormalized == 0.1)
    #expect(state.focus == 0.65)
    #expect(state.autoExposure == "Continuous")
    #expect(state.availableAudioInputs == ["None", "iPhone Microphone"])
    #expect(state.lenses.map(\.id) == ["Lens13mm", "LensWASecondary", "LensFront"])
    #expect(state.activeLensID == "LensWASecondary")
    #expect(state.lenses[2].label == "Frontal 0.5×")
}

/// Formatos aceitos pelo iPhone em 20/10: ângulo em graus (inclusive fracionário) com
/// `measurement` = `ShutterAngle`; centésimos de grau, como na doc, dão 400.
@Test func shutterRequestBodies() {
    let state = CameraState()
    state.apply(property: "/video/shutter", value: ["shutterAngle": 112.5])
    #expect(state.shutter == .angle(112.5))
    #expect(Shutter.angle(327.27272727272725).requestBody["shutterAngle"] as? Double == 327.27272727272725)
    #expect(Shutter.angle(180).measurement == "ShutterAngle")
    #expect(Shutter.speed(60).requestBody["shutterSpeed"] as? Int == 60)
    #expect(Shutter.speed(60).measurement == "ShutterSpeed")
    state.apply(property: "/video/shutter/measurement", value: ["measurement": "ShutterAngle"])
    #expect(state.shutterMeasurement == "ShutterAngle")
}

@Test func silentInputIsTheFirstSupportedOneInAnyLanguage() {
    let state = CameraState()
    #expect(state.isSilent("None"))
    // iPhone em português, como chegou em 21/10/2026.
    state.apply(property: "/audio/channel/0/supportedInputs", value: ["items": [
        ["input": "Não", "available": true], ["input": "Microfone do iPhone", "available": true],
        ["input": "Wireless microphone", "available": true],
    ]])
    #expect(state.silentInput == "Não")
    state.apply(property: "/audio/channel/0/input", value: ["input": "Não"])
    #expect(state.recordsSilence)
    state.apply(property: "/audio/channel/0/input", value: ["input": "Wireless microphone"])
    #expect(!state.recordsSilence)
}

@Test func batteryAndProductComeFromTheCamera() {
    let state = CameraState()
    // Como o iPhone mandou em 21/10/2026.
    state.apply(property: "/camera/power", value: [
        "batteries": [["statusFlags": ["Battery Is Present", "Battery Is Charging"], "chargeRemainingPercent": 60, "milliVolt": 0]],
        "milliVolt": 0, "source": "AC",
    ])
    #expect(state.batteryPercent == 60)
    #expect(state.batteryCharging)
    #expect(state.batteryLevel == .normal)
    state.apply(property: "/camera/power", value: ["batteries": [["statusFlags": ["Battery Is Present"], "chargeRemainingPercent": 20]]])
    #expect(!state.batteryCharging)
    #expect(state.batteryLevel == .warning)
    state.apply(property: "/camera/power", value: ["batteries": [["chargeRemainingPercent": 10]]])
    #expect(state.batteryLevel == .critical)
    state.apply(property: "/system/product", value: ["productName": "iPhone 17 Pro Max", "softwareVersion": "3.5.200045", "deviceName": "A"])
    #expect(state.deviceName == "A")
    #expect(state.productName == "iPhone 17 Pro Max")
}

@Test func builtInMicPublishesAFixedGainRange() {
    let state = CameraState()
    state.apply(property: "/audio/channel/0/input/description", value: ["description": [
        "gainRange": ["Max": 1, "Min": 1],
        "capabilities": [["PhantomPower": false, "LowCutFilter": false]],
    ]])
    #expect(state.audioGainRange == 1...1)
}

@Test func recordFormatAndItsOptions() {
    let state = CameraState()
    // Como o iPhone mandou em 21/10/2026.
    state.apply(property: "/system/format", value: [
        "frameRate": "30", "codec": "HEVC (H.265):Max", "offSpeedEnabled": false, "offSpeedFrameRate": 30,
        "resolutionDescriptor": ["aspectRatio": "16:9", "description": "4K", "group": "4K"],
        "recordResolution": ["width": 3840, "height": 2160], "sensorResolution": ["width": 3840, "height": 2160],
    ])
    #expect(state.recordFormat?.summary == "4K 30p")
    #expect(RecordFormat.family("HEVC (H.265):Max") == "HEVC (H.265)")
    #expect(RecordFormat.quality("Apple ProRes 422:Default") == "Default")
    state.apply(property: "/system/supportedFormats", value: ["supportedFormats": [[
        "codecs": ["HEVC (H.265):Max", "H.264:Max"], "frameRates": ["24", "30"],
        "resolutionDescriptor": ["description": "Open Gate", "group": "Open Gate", "aspectRatio": "4:3"],
        "recordResolution": ["width": 4032, "height": 3024], "sensorResolution": ["width": 4032, "height": 3024],
    ]]])
    let option = try! #require(state.supportedFormats.first)
    #expect(option.resolution == "Open Gate")
    let body = state.recordFormat!.body(option: option, frameRate: "24", codec: "H.264:Max")
    #expect(body["frameRate"] as? String == "24")
    #expect((body["recordResolution"] as? [String: Int])?["width"] == 4032)
}
