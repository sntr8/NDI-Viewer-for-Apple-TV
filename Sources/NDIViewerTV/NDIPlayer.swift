import AVFoundation
import CoreMedia

/// Renders the receiver's frames through an `AVSampleBufferRenderSynchronizer`.
///
/// Video and audio arrive stamped against one NDI sender clock, so handing both
/// to a single synchronizer is what keeps them in sync: it drives the display
/// layer and the audio renderer off one timeline instead of letting each free-run.
final class NDIPlayer: ObservableObject {

    let displayLayer = AVSampleBufferDisplayLayer()

    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let audioRenderer = AVSampleBufferAudioRenderer()

    /// How much media to queue up before starting the clock. Live NDI arrives
    /// at roughly realtime, so with no cushion at all the renderers underrun on
    /// the first hiccup; a fifth of a second is enough to ride those out without
    /// adding latency anyone notices.
    private let prerollDuration = CMTime(value: 1, timescale: 5)

    /// Called when the source's timeline has moved so far from the render clock
    /// that only rebuilding it will recover. Set this to reset the receiver.
    var onTimelineBroken: (() -> Void)?

    /// How far ahead of the clock the audio queue should sit. Below zero means
    /// buffers are arriving already late and the renderer is discarding them;
    /// far above means latency nobody asked for. A sender clock stepping — an
    /// NTP correction, a restart — puts depth outside this band in one jump and
    /// it never comes back on its own.
    private let healthyDepth: ClosedRange<Double> = -0.05...2.0
    private let unhealthyBuffersBeforeResync = 5

    /// How much audio to keep queued ahead of the clock.
    private let targetDepth = 0.25

    /// The sender's clock and the Apple TV's audio clock differ by a couple of
    /// tens of ppm — measured at -21.8 ppm over a two-hour run — so a fixed rate
    /// of 1.0 drains the queue by ~170ms an hour until it underruns. Rather than
    /// let it fall off the end and flush, the rate is trimmed continuously to
    /// hold `targetDepth`. The corrections are far too small to hear: the clamp
    /// below is 500 ppm, under a hundredth of a semitone.
    private let servoGain = 2e-3
    private let maxRateCorrection = 5e-4
    private var lastServoUpdate = CFAbsoluteTimeGetCurrent()

    private let lock = NSLock()
    private var hasStartedClock = false
    private var firstPresentationTime: CMTime?
    private var unhealthyDepthCount = 0

    init() {
        displayLayer.videoGravity = .resizeAspect
        // Plain resampling, so a rate trim behaves like a varispeed rather than
        // invoking pitch correction on every sample.
        audioRenderer.audioTimePitchAlgorithm = .varispeed
        synchronizer.addRenderer(displayLayer.sampleBufferRenderer)
        synchronizer.addRenderer(audioRenderer)
    }

    // MARK: - Feeding

    func enqueueVideo(_ sampleBuffer: CMSampleBuffer) {
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed {
            renderer.flush()
        }
        renderer.enqueue(sampleBuffer)
        startClockIfReady(sampleBuffer.presentationTimeStamp)
    }

    func enqueueAudio(_ sampleBuffer: CMSampleBuffer) {
        audioRenderer.enqueue(sampleBuffer)
        startClockIfReady(sampleBuffer.presentationTimeStamp)
        checkBufferDepth(sampleBuffer)
    }

    private var lastDepthReport = CFAbsoluteTimeGetCurrent()

    /// Watches how far ahead of the clock the audio queue is running, and
    /// rebuilds the timeline if it leaves the healthy band for long enough to
    /// rule out a transient. Costs one audible glitch; the alternative is
    /// silence that persists until the source is reselected.
    private func checkBufferDepth(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        let started = hasStartedClock
        lock.unlock()
        guard started else { return }

        let end = sampleBuffer.presentationTimeStamp + sampleBuffer.duration
        let depth = (end - synchronizer.currentTime()).seconds

        let now = CFAbsoluteTimeGetCurrent()
        if now - lastDepthReport >= 10 {
            lastDepthReport = now
            NSLog(String(format: "NDI-AUDIO depth=%.1fms rate=%.6f", depth * 1000, synchronizer.rate))
        }

        guard !healthyDepth.contains(depth) else {
            unhealthyDepthCount = 0
            trimRate(forDepth: depth, now: now)
            return
        }
        unhealthyDepthCount += 1
        guard unhealthyDepthCount >= unhealthyBuffersBeforeResync else { return }
        unhealthyDepthCount = 0

        NSLog(String(format: "NDI-AUDIO timeline break (depth=%.0fms) — rebuilding", depth * 1000))

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reset()
            self.onTimelineBroken?()
        }
    }

    /// Holds the clock at zero until `prerollDuration` of media has been queued,
    /// then starts it from the first frame's timestamp.
    private func startClockIfReady(_ presentationTime: CMTime) {
        guard presentationTime.isNumeric else { return }

        lock.lock()
        if firstPresentationTime == nil { firstPresentationTime = presentationTime }
        guard !hasStartedClock, let first = firstPresentationTime else {
            lock.unlock()
            return
        }
        guard presentationTime - first >= prerollDuration else {
            lock.unlock()
            return
        }
        hasStartedClock = true
        lock.unlock()

        synchronizer.setRate(1.0, time: first)
    }

    /// Nudges the clock so the queue converges on `targetDepth`. A queue running
    /// short means the clock is outpacing the source, so it is slowed slightly,
    /// and vice versa.
    private func trimRate(forDepth depth: Double, now: CFAbsoluteTime) {
        guard now - lastServoUpdate >= 2 else { return }
        lastServoUpdate = now

        let correction = min(max((depth - targetDepth) * servoGain, -maxRateCorrection), maxRateCorrection)
        let rate = Float(1.0 + correction)
        DispatchQueue.main.async { [weak self] in
            // Assigning rate keeps the clock where it is; setRate(_:time:) would
            // reposition it and undo the sync.
            self?.synchronizer.rate = rate
        }
    }

    // MARK: - Lifecycle

    /// Drops everything queued and rewinds the clock, ready for a new source.
    func reset() {
        synchronizer.rate = 0
        displayLayer.sampleBufferRenderer.flush()
        audioRenderer.flush()
        lock.withLock {
            hasStartedClock = false
            firstPresentationTime = nil
        }
        unhealthyDepthCount = 0
    }

    static func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            NSLog("NDIViewerTV: could not activate the audio session — \(error)")
        }
    }
}
