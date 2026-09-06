import Foundation
import CoreVideo
import CoreMedia

struct NDISourceInfo: Identifiable, Hashable {
    let id: String          // p_ndi_name, which NDI guarantees unique per source
    let name: String
    let urlAddress: String
}

/// Wraps the NDI C SDK (via the bridging header) for source discovery and
/// video receive, and hands decoded frames to the display layer as
/// CMSampleBuffers.
final class NDIReceiver: ObservableObject {

    @Published private(set) var sources: [NDISourceInfo] = []
    @Published private(set) var isConnected = false
    @Published private(set) var connectedSourceName: String?
    @Published private(set) var lastError: String?

    /// Called on an arbitrary background queue with a ready-to-display frame.
    var onVideoSampleBuffer: ((CMSampleBuffer) -> Void)?

    private var findInstance: NDIlib_find_instance_t?
    private var recvInstance: NDIlib_recv_instance_t?

    private let discoveryQueue = DispatchQueue(label: "ndi.discovery")
    private let captureQueue = DispatchQueue(label: "ndi.capture")

    private var isDiscovering = false
    private var isCapturing = false

    private var sdkInitialized = false

    func start() {
        guard !sdkInitialized else { return }
        guard NDIlib_initialize() else {
            lastError = "NDIlib_initialize() failed — this CPU/OS may not support NDI."
            return
        }
        sdkInitialized = true
        startDiscovery()
    }

    func stop() {
        disconnect()
        stopDiscovery()
        if sdkInitialized {
            NDIlib_destroy()
            sdkInitialized = false
        }
    }

    // MARK: - Discovery

    private func startDiscovery() {
        var settings = NDIlib_find_create_t()
        settings.show_local_sources = true
        settings.p_groups = nil
        settings.p_extra_ips = nil

        guard let instance = NDIlib_find_create_v2(&settings) else {
            lastError = "Could not create NDI find instance."
            return
        }
        findInstance = instance
        isDiscovering = true

        discoveryQueue.async { [weak self] in
            self?.discoveryLoop()
        }
    }

    private func discoveryLoop() {
        guard let instance = findInstance else { return }
        while isDiscovering {
            // Blocks up to 1s, or returns early once the source list changes.
            _ = NDIlib_find_wait_for_sources(instance, 1000)

            var count: UInt32 = 0
            guard let rawSources = NDIlib_find_get_current_sources(instance, &count) else {
                continue
            }

            var found: [NDISourceInfo] = []
            for i in 0..<Int(count) {
                let source = rawSources[i]
                guard let namePtr = source.p_ndi_name else { continue }
                let name = String(cString: namePtr)
                let url = source.p_url_address.map { String(cString: $0) } ?? ""
                found.append(NDISourceInfo(id: name, name: name, urlAddress: url))
            }

            DispatchQueue.main.async { [weak self] in
                self?.sources = found
            }
        }
    }

    private func stopDiscovery() {
        isDiscovering = false
        if let instance = findInstance {
            NDIlib_find_destroy(instance)
            findInstance = nil
        }
    }

    // MARK: - Connect / receive

    func connect(to source: NDISourceInfo) {
        disconnect()

        // NDIlib_recv_create_v3 copies the strings it's given, so it's safe
        // to free our own copies right after the call returns.
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

        guard let instance = NDIlib_recv_create_v3(&createSettings) else {
            lastError = "Could not create NDI receiver for \(source.name)."
            return
        }

        recvInstance = instance
        isConnected = true
        connectedSourceName = source.name
        isCapturing = true

        captureQueue.async { [weak self] in
            self?.captureLoop()
        }
    }

    func disconnect() {
        isCapturing = false
        if let instance = recvInstance {
            NDIlib_recv_destroy(instance)
            recvInstance = nil
        }
        isConnected = false
        connectedSourceName = nil
    }

    private func captureLoop() {
        guard let instance = recvInstance else { return }

        while isCapturing {
            var videoFrame = NDIlib_video_frame_v2_t()
            let frameType = NDIlib_recv_capture_v2(instance, &videoFrame, nil, nil, 1000)

            switch frameType {
            case NDIlib_frame_type_video:
                handleVideoFrame(videoFrame, instance: instance)
            case NDIlib_frame_type_error:
                DispatchQueue.main.async { [weak self] in
                    self?.lastError = "NDI receive error."
                }
                isCapturing = false
            default:
                // none / audio / metadata / status_change — nothing to render.
                break
            }
        }
    }

    /// Wraps the frame's pixel data into a CVPixelBuffer with no copy: the
    /// buffer's release callback frees the NDI frame once the last reference
    /// (including whatever AVSampleBufferDisplayLayer is holding) goes away.
    private func handleVideoFrame(_ frame: NDIlib_video_frame_v2_t, instance: NDIlib_recv_instance_t) {
        guard let data = frame.p_data else {
            var emptyFrame = frame
            NDIlib_recv_free_video_v2(instance, &emptyFrame)
            return
        }

        let width = Int(frame.xres)
        let height = Int(frame.yres)
        let bytesPerRow = Int(frame.line_stride_in_bytes)

        let context = Unmanaged.passRetained(
            NDIFrameOwner(frame: frame, instance: instance)
        ).toOpaque()

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreateWithBytes(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            UnsafeMutableRawPointer(data),
            bytesPerRow,
            { releaseContext, _ in
                guard let releaseContext else { return }
                Unmanaged<NDIFrameOwner>.fromOpaque(releaseContext).release()
            },
            context,
            nil,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let pixelBuffer else {
            Unmanaged<NDIFrameOwner>.fromOpaque(context).release()
            return
        }

        var formatDescription: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard let formatDescription else { return }

        var timingInfo = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        )

        if let sampleBuffer {
            onVideoSampleBuffer?(sampleBuffer)
        }
    }

}

/// Keeps an NDI video frame alive for as long as the CVPixelBuffer built on
/// top of its raw bytes is alive, then hands it back to the SDK.
private final class NDIFrameOwner {
    private var frame: NDIlib_video_frame_v2_t
    private let instance: NDIlib_recv_instance_t

    init(frame: NDIlib_video_frame_v2_t, instance: NDIlib_recv_instance_t) {
        self.frame = frame
        self.instance = instance
    }

    deinit {
        NDIlib_recv_free_video_v2(instance, &frame)
    }
}
