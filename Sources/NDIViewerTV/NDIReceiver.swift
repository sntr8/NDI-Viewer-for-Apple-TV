import Foundation
import CoreVideo
import CoreMedia

struct NDISourceInfo: Identifiable, Hashable {
    let id: String          // p_ndi_name, which NDI guarantees unique per source
    let name: String
    let urlAddress: String
}

/// Discovers NDI sources and, once connected to one, turns its video and audio
/// frames into `CMSampleBuffer`s on a shared timeline.
///
/// Threading: the NDI find instance is only ever touched on `discoveryQueue`
/// and the recv instance only on `captureQueue`. Both are serial, so
/// connect/disconnect just enqueue work rather than tearing an instance out
/// from under a blocking capture call.
final class NDIReceiver: ObservableObject {

    @Published private(set) var sources: [NDISourceInfo] = []
    @Published private(set) var isConnected = false
    @Published private(set) var connectedSourceName: String?
    @Published private(set) var isScanning = false
    @Published private(set) var lastError: String?

    /// Frames, on the capture queue. Presentation timestamps for video and
    /// audio share one timeline, rebased to zero at the first frame.
    var onVideoSampleBuffer: ((CMSampleBuffer) -> Void)?
    var onAudioSampleBuffer: ((CMSampleBuffer) -> Void)?

    private var findInstance: NDIlib_find_instance_t?
    private var recvInstance: NDIlib_recv_instance_t?

    private let discoveryQueue = DispatchQueue(label: "ndi.discovery")
    private let captureQueue = DispatchQueue(label: "ndi.capture", qos: .userInitiated)

    private let state = StateFlags()
    private var sdkInitialized = false

    /// Rebases NDI's absolute 100ns timestamps onto a zero-based timeline, so
    /// CMTime arithmetic stays well away from Int64 overflow. Capture queue only.
    private var timestampBase: Int64?
    private var pixelBufferPool: CVPixelBufferPool?
    private var pixelBufferPoolSize: (width: Int, height: Int)?
    private var videoFormatDescription: CMVideoFormatDescription?
    private var audioFormatDescription: CMAudioFormatDescription?
    private var audioFormatShape: (sampleRate: Int, channels: Int)?

    private var audioAnchor: CMTime?
    private var audioAnchorSampleRate: Int?
    private var audioSamplesEmitted: Int64 = 0
    private var lastAudioArrival: CFAbsoluteTime?

    // MARK: - Lifecycle

    func start() {
        guard !sdkInitialized else { return }
        guard NDIlib_initialize() else {
            lastError = "NDIlib_initialize() failed — this device may not support NDI."
            return
        }
        sdkInitialized = true
        state.isDiscovering = true
        isScanning = true
        discoveryQueue.async { [weak self] in
            self?.runDiscovery()
        }
    }

    func stop() {
        guard sdkInitialized else { return }
        sdkInitialized = false
        disconnect()
        state.isDiscovering = false
        // NDIlib_destroy() has to be last: both loops are still holding
        // instances, so it's chained behind the discovery queue (which unwinds
        // and frees the finder) and then the capture queue (likewise the
        // receiver). Both are serial, so the ordering holds.
        discoveryQueue.async { [weak self] in
            guard let self else { return }
            self.destroyFinder()
            self.captureQueue.async {
                NDIlib_destroy()
            }
        }
    }

    // MARK: - Discovery

    /// Drops the current finder and starts a fresh scan. Discovery is
    /// continuous anyway; this is for when a source list looks stale.
    func refresh() {
        guard sdkInitialized else { return }
        isScanning = true
        sources = []
        state.shouldRestartFinder = true
    }

    private func runDiscovery() {
        while state.isDiscovering {
            if findInstance == nil || state.shouldRestartFinder {
                state.shouldRestartFinder = false
                destroyFinder()
                guard createFinder() else {
                    Thread.sleep(forTimeInterval: 1)
                    continue
                }
            }
            guard let instance = findInstance else { continue }

            // Returns early the moment the source list changes; the timeout
            // just bounds how long a refresh has to wait to be noticed.
            _ = NDIlib_find_wait_for_sources(instance, 250)

            var count: UInt32 = 0
            guard let rawSources = NDIlib_find_get_current_sources(instance, &count) else { continue }

            // These pointers are only valid until the next call on this
            // instance, so the strings get copied out right here.
            var found: [NDISourceInfo] = []
            for i in 0..<Int(count) {
                let source = rawSources[i]
                guard let namePtr = source.p_ndi_name else { continue }
                let name = String(cString: namePtr)
                let url = source.p_url_address.map { String(cString: $0) } ?? ""
                found.append(NDISourceInfo(id: name, name: name, urlAddress: url))
            }
            found.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.sources != found { self.sources = found }
                self.isScanning = false
            }
        }
        destroyFinder()
    }

    private func createFinder() -> Bool {
        var settings = NDIlib_find_create_t()
        settings.show_local_sources = true
        settings.p_groups = nil
        settings.p_extra_ips = nil

        guard let instance = NDIlib_find_create_v2(&settings) else {
            DispatchQueue.main.async { [weak self] in
                self?.lastError = "Could not create NDI find instance."
            }
            return false
        }
        findInstance = instance
        return true
    }

    private func destroyFinder() {
        if let instance = findInstance {
            NDIlib_find_destroy(instance)
            findInstance = nil
        }
    }

    // MARK: - Connect / receive

    func connect(to source: NDISourceInfo) {
        guard sdkInitialized else { return }
        disconnect()
        isConnected = true
        connectedSourceName = source.name
        state.isCapturing = true
        captureQueue.async { [weak self] in
            self?.openAndCapture(source)
        }
    }

    func disconnect() {
        state.isCapturing = false
        isConnected = false
        connectedSourceName = nil
        captureQueue.async { [weak self] in
            self?.destroyReceiver()
        }
    }

    private func openAndCapture(_ source: NDISourceInfo) {
        // NDIlib_recv_create_v3 copies the strings it's handed, so the local
        // copies can go away as soon as it returns.
        let namePtr = strdup(source.name)
        let urlPtr = source.urlAddress.isEmpty ? nil : strdup(source.urlAddress)
        defer {
            free(namePtr)
            free(urlPtr)
        }

        var sourceStruct = NDIlib_source_t()
        sourceStruct.p_ndi_name = UnsafePointer(namePtr)
        sourceStruct.p_url_address = urlPtr.map { UnsafePointer($0) }

        var createSettings = NDIlib_recv_create_v3_t()
        createSettings.source_to_connect_to = sourceStruct
        createSettings.color_format = NDIlib_recv_color_format_BGRX_BGRA
        createSettings.bandwidth = NDIlib_recv_bandwidth_highest
        createSettings.allow_video_fields = false
        createSettings.p_ndi_recv_name = nil

        guard let instance = NDIlib_recv_create_v3(&createSettings) else {
            DispatchQueue.main.async { [weak self] in
                self?.lastError = "Could not create NDI receiver for \(source.name)."
                self?.isConnected = false
                self?.connectedSourceName = nil
            }
            return
        }

        recvInstance = instance
        timestampBase = nil
        captureLoop(instance)
        destroyReceiver()
    }

    private func captureLoop(_ instance: NDIlib_recv_instance_t) {
        while state.isCapturing {
            var videoFrame = NDIlib_video_frame_v2_t()
            var audioFrame = NDIlib_audio_frame_v3_t()

            // 100ms keeps teardown responsive when a source has gone quiet.
            switch NDIlib_recv_capture_v3(instance, &videoFrame, &audioFrame, nil, 100) {
            case NDIlib_frame_type_video:
                handleVideoFrame(videoFrame)
                NDIlib_recv_free_video_v2(instance, &videoFrame)
            case NDIlib_frame_type_audio:
                handleAudioFrame(audioFrame)
                NDIlib_recv_free_audio_v3(instance, &audioFrame)
            case NDIlib_frame_type_error:
                DispatchQueue.main.async { [weak self] in
                    self?.lastError = "Lost the connection to this NDI source."
                }
                state.isCapturing = false
            default:
                // none / metadata / status_change — nothing to render.
                break
            }
        }
    }

    private func destroyReceiver() {
        if let instance = recvInstance {
            NDIlib_recv_destroy(instance)
            recvInstance = nil
        }
        pixelBufferPool = nil
        pixelBufferPoolSize = nil
        videoFormatDescription = nil
        audioFormatDescription = nil
        audioFormatShape = nil
        timestampBase = nil
        audioAnchor = nil
        audioAnchorSampleRate = nil
        audioSamplesEmitted = 0
        lastAudioArrival = nil
    }

    // MARK: - Timeline

    /// Drops the shared time base so the next frames re-establish the timeline
    /// from scratch. Used when the sender's clock steps far enough that the
    /// existing base would leave every subsequent frame late.
    func resetTimeline() {
        captureQueue.async { [weak self] in
            guard let self else { return }
            self.timestampBase = nil
            self.audioAnchor = nil
            self.audioAnchorSampleRate = nil
            self.audioSamplesEmitted = 0
        }
    }

    /// NDI stamps video and audio from the same sender clock, so rebasing both
    /// against one base is what actually keeps them in sync downstream.
    private func presentationTime(forTimestamp timestamp: Int64, timecode: Int64) -> CMTime {
        let ticks = timestamp == NDIlib_recv_timestamp_undefined ? timecode : timestamp
        if timestampBase == nil { timestampBase = ticks }
        return CMTime(value: ticks - (timestampBase ?? ticks), timescale: 10_000_000)
    }

    // MARK: - Video

    private func handleVideoFrame(_ frame: NDIlib_video_frame_v2_t) {
        guard let data = frame.p_data else { return }
        guard frame.FourCC == NDIlib_FourCC_video_type_BGRA
                || frame.FourCC == NDIlib_FourCC_video_type_BGRX else {
            reportUnsupportedVideoFormat(frame.FourCC)
            return
        }

        let width = Int(frame.xres)
        let height = Int(frame.yres)
        guard width > 0, height > 0 else { return }

        guard let pool = pixelBufferPool(width: width, height: height) else { return }

        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer else { return }

        // AVSampleBufferDisplayLayer only reliably renders IOSurface-backed
        // buffers, which rules out wrapping NDI's own memory with
        // CVPixelBufferCreateWithBytes — hence the copy into a pooled buffer.
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let destination = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let sourceStride = Int(frame.line_stride_in_bytes)
            let destinationStride = CVPixelBufferGetBytesPerRow(pixelBuffer)
            if sourceStride == destinationStride {
                memcpy(destination, data, destinationStride * height)
            } else {
                let rowBytes = min(sourceStride, destinationStride)
                for row in 0..<height {
                    memcpy(destination + row * destinationStride,
                           data + row * sourceStride,
                           rowBytes)
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        guard let formatDescription = videoFormatDescription(for: pixelBuffer) else { return }

        let duration = frame.frame_rate_N > 0 && frame.frame_rate_D > 0
            ? CMTime(value: CMTimeValue(frame.frame_rate_D), timescale: CMTimeScale(frame.frame_rate_N))
            : CMTime.invalid
        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: presentationTime(forTimestamp: frame.timestamp, timecode: frame.timecode),
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return }

        onVideoSampleBuffer?(sampleBuffer)
    }

    private func pixelBufferPool(width: Int, height: Int) -> CVPixelBufferPool? {
        if let pool = pixelBufferPool, pixelBufferPoolSize?.width == width, pixelBufferPoolSize?.height == height {
            return pool
        }
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess else {
            return nil
        }
        // A new pool means new dimensions, so the cached format description
        // no longer describes the frames coming out of it.
        videoFormatDescription = nil
        pixelBufferPool = pool
        pixelBufferPoolSize = (width, height)
        return pool
    }

    private func videoFormatDescription(for pixelBuffer: CVPixelBuffer) -> CMVideoFormatDescription? {
        if let existing = videoFormatDescription { return existing }
        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &description
        ) == noErr else { return nil }
        videoFormatDescription = description
        return description
    }

    private func reportUnsupportedVideoFormat(_ fourCC: NDIlib_FourCC_video_type_e) {
        let code = UInt32(truncatingIfNeeded: fourCC.rawValue)
        let tag = String(bytes: (0..<4).map { UInt8((code >> (8 * $0)) & 0xFF) }, encoding: .ascii) ?? "????"
        DispatchQueue.main.async { [weak self] in
            self?.lastError = "Unsupported video format from this source (\(tag))."
        }
    }

    // MARK: - Audio

    private func handleAudioFrame(_ frame: NDIlib_audio_frame_v3_t) {
        guard frame.FourCC == NDIlib_FourCC_audio_type_FLTP else { return }

        let arrival = CFAbsoluteTimeGetCurrent()
        if let previous = lastAudioArrival, arrival - previous > 0.25 {
            NSLog(String(format: "NDI-AUDIO stream gap %.2fs", arrival - previous))
        }
        lastAudioArrival = arrival

        let channels = Int(frame.no_channels)
        let samples = Int(frame.no_samples)
        let sampleRate = Int(frame.sample_rate)
        guard channels > 0, samples > 0, sampleRate > 0 else { return }

        guard let formatDescription = audioFormatDescription(sampleRate: sampleRate, channels: channels) else { return }

        let bytesPerFrame = channels * MemoryLayout<Float>.size
        let totalBytes = bytesPerFrame * samples

        // Let CoreMedia own the allocation, then convert NDI's planar audio
        // straight into it — no intermediate buffer to free by hand.
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: totalBytes,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: totalBytes,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        ) == noErr, let blockBuffer else { return }

        var destination: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: nil,
            dataPointerOut: &destination
        ) == noErr, let destination else { return }

        var source = frame
        var interleaved = NDIlib_audio_frame_interleaved_32f_t()
        interleaved.sample_rate = frame.sample_rate
        interleaved.no_channels = frame.no_channels
        interleaved.no_samples = frame.no_samples
        interleaved.timecode = frame.timecode
        interleaved.p_data = UnsafeMutableRawPointer(destination).assumingMemoryBound(to: Float.self)
        guard NDIlib_util_audio_to_interleaved_32f_v3(&source, &interleaved) else { return }

        let ndiPTS = presentationTime(forTimestamp: frame.timestamp, timecode: frame.timecode)
        let pts = audioPresentationTime(matching: ndiPTS, samples: samples, sampleRate: sampleRate)

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sampleSize = bytesPerFrame

        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: samples,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return }

        onAudioSampleBuffer?(sampleBuffer)
    }

    /// NDI's `timestamp` marks when the sender *submitted* a frame, so it carries
    /// that side's scheduling jitter — measured on real traffic at ±40 to ±105
    /// samples per buffer, averaging to zero. Stamping audio with it directly
    /// puts a gap or an overlap under every buffer, and the renderer turns each
    /// of those seams into a click.
    ///
    /// Audio is therefore clocked by counting samples from a single anchor, which
    /// is contiguous by construction. The anchor is only reset when the source's
    /// own timeline moves further than jitter can explain — a genuine
    /// discontinuity such as a reconnect or a format change.
    private func audioPresentationTime(matching ndiPTS: CMTime, samples: Int, sampleRate: Int) -> CMTime {
        let reanchorThreshold = 0.1

        if let anchor = audioAnchor, audioAnchorSampleRate == sampleRate {
            let pts = anchor + CMTime(value: audioSamplesEmitted, timescale: CMTimeScale(sampleRate))
            if abs((pts - ndiPTS).seconds) < reanchorThreshold {
                audioSamplesEmitted += Int64(samples)
                return pts
            }
        }

        if let anchor = audioAnchor {
            let snapped = (anchor + CMTime(value: audioSamplesEmitted, timescale: CMTimeScale(audioAnchorSampleRate ?? sampleRate)))
            NSLog(String(format: "NDI-AUDIO re-anchor by %+.1fms", (ndiPTS - snapped).seconds * 1000))
        }
        audioAnchor = ndiPTS
        audioAnchorSampleRate = sampleRate
        audioSamplesEmitted = Int64(samples)
        return ndiPTS
    }

    private func audioFormatDescription(sampleRate: Int, channels: Int) -> CMAudioFormatDescription? {
        if let existing = audioFormatDescription,
           audioFormatShape?.sampleRate == sampleRate,
           audioFormatShape?.channels == channels {
            return existing
        }
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian,
            mBytesPerPacket: UInt32(channels * MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(channels * MemoryLayout<Float>.size),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var description: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &description
        ) == noErr else { return nil }
        audioFormatDescription = description
        audioFormatShape = (sampleRate, channels)
        return description
    }
}

/// The handful of booleans that genuinely cross threads: set from the main
/// queue, read inside the capture and discovery loops.
private final class StateFlags {
    private let lock = NSLock()
    private var _isDiscovering = false
    private var _isCapturing = false
    private var _shouldRestartFinder = false

    var isDiscovering: Bool {
        get { lock.withLock { _isDiscovering } }
        set { lock.withLock { _isDiscovering = newValue } }
    }
    var isCapturing: Bool {
        get { lock.withLock { _isCapturing } }
        set { lock.withLock { _isCapturing = newValue } }
    }
    var shouldRestartFinder: Bool {
        get { lock.withLock { _shouldRestartFinder } }
        set { lock.withLock { _shouldRestartFinder = newValue } }
    }
}
