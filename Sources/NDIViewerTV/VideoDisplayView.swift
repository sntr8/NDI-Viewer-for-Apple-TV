import SwiftUI
import AVFoundation

/// Hosts the player's display layer and sizes it to the view.
final class VideoDisplayLayerView: UIView {
    private let player: NDIPlayer

    init(player: NDIPlayer) {
        self.player = player
        super.init(frame: .zero)
        backgroundColor = .black
        layer.addSublayer(player.displayLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The display layer isn't in the Auto Layout system, so it gets its
        // frame set by hand rather than through constraints.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        player.displayLayer.frame = bounds
        CATransaction.commit()
    }
}

struct VideoDisplayView: UIViewRepresentable {
    let player: NDIPlayer

    func makeUIView(context: Context) -> VideoDisplayLayerView {
        VideoDisplayLayerView(player: player)
    }

    func updateUIView(_ uiView: VideoDisplayLayerView, context: Context) {}
}
