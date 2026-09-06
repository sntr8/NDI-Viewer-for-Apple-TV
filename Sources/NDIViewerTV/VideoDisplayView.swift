import SwiftUI
import AVFoundation

/// A UIView backed by AVSampleBufferDisplayLayer, fed frames pushed in from
/// NDIReceiver's capture loop.
final class VideoDisplayLayerView: UIView {
    override static var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    var displayLayer: AVSampleBufferDisplayLayer {
        layer as! AVSampleBufferDisplayLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        displayLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        displayLayer.videoGravity = .resizeAspect
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        displayLayer.enqueue(sampleBuffer)
    }
}

struct VideoDisplayView: UIViewRepresentable {
    @ObservedObject var receiver: NDIReceiver

    func makeUIView(context: Context) -> VideoDisplayLayerView {
        let view = VideoDisplayLayerView()
        receiver.onVideoSampleBuffer = { [weak view] sampleBuffer in
            DispatchQueue.main.async {
                view?.enqueue(sampleBuffer)
            }
        }
        return view
    }

    func updateUIView(_ uiView: VideoDisplayLayerView, context: Context) {}
}
