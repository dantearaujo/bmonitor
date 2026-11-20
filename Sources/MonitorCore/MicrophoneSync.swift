import CoreMedia

/// Estimates the relation between the sender's PTS and the Mac's host clock.
/// Arrival jitter can only make an observation later, so use the earliest
/// arrivals within each window to estimate the clock rate.
struct MicrophoneSync {
    private var anchor: (host: Double, video: Double)?
    private var previousWindow: (host: Double, video: Double)?
    private var windowStart: Double = 0
    private var earliest: (host: Double, video: Double)?
    private var rate: Double = 1
    private var lastVideo: Double?

    /// Returns true when the stream starts a new timestamp sequence.
    mutating func observe(video: CMTime, arrival: CMTime) -> Bool {
        guard video.isNumeric, arrival.isNumeric else { return false }
        let point = (host: arrival.seconds, video: video.seconds)
        guard let anchor, let lastVideo, point.video > lastVideo,
            abs(point.video - (anchor.video + (point.host - anchor.host) * rate)) < 2
        else {
            self = Self()
            anchor = point
            windowStart = point.host
            earliest = point
            lastVideo = point.video
            return true
        }
        self.lastVideo = point.video
        if let earliest {
            if point.video - (point.host - earliest.host) * rate > earliest.video {
                self.earliest = point
            }
        } else {
            earliest = point
        }
        if point.host - windowStart >= 8, let earliest {
            if let previousWindow, earliest.host - previousWindow.host >= 4 {
                let measured = (earliest.video - previousWindow.video) / (earliest.host - previousWindow.host)
                let bounded = min(max(measured, 0.999), 1.001)
                // Change the slope without jumping the recording timeline.
                self.anchor = (point.host, anchor.video + (point.host - anchor.host) * rate)
                rate += 0.25 * (bounded - rate)
            }
            self.previousWindow = earliest
            self.earliest = nil
            windowStart = point.host
        }
        return false
    }

    func presentationTime(for hostTime: CMTime, delay: CMTime) -> CMTime? {
        guard let anchor, hostTime.isNumeric, let lastVideo else { return nil }
        let time = anchor.video + (hostTime.seconds - anchor.host) * rate + delay.seconds
        guard abs(time - lastVideo) < 2 else { return nil }
        return CMTime(seconds: time, preferredTimescale: 48_000)
    }
}
