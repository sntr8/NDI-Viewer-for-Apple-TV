import SwiftUI

struct ContentView: View {
    @StateObject private var receiver = NDIReceiver()
    // @StateObject, not @State: the initialiser is autoclosured, so the
    // synchronizer and its renderers are built once rather than on every
    // re-evaluation of this view.
    @StateObject private var player = NDIPlayer()
    @FocusState private var playbackHasFocus: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if receiver.isConnected {
                playback
            } else {
                sourceList
            }
        }
        .onAppear {
            receiver.onVideoSampleBuffer = { [player] in player.enqueueVideo($0) }
            receiver.onAudioSampleBuffer = { [player] in player.enqueueAudio($0) }
            player.onTimelineBroken = { [receiver] in receiver.resetTimeline() }
            NDIPlayer.configureAudioSession()
            receiver.start()
        }
        .onDisappear {
            receiver.stop()
            player.reset()
        }
    }

    // MARK: - Playback

    private var playback: some View {
        VideoDisplayView(player: player)
            .ignoresSafeArea()
            // Nothing in a full-screen video is focusable on its own, and the
            // Menu button only reaches a view that's in the focus chain — so
            // it's made focusable and then handed focus explicitly.
            .focusable()
            .focused($playbackHasFocus)
            .onAppear { playbackHasFocus = true }
            .onExitCommand {
                receiver.disconnect()
                player.reset()
            }
    }

    // MARK: - Source list

    private var sourceList: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text("NDI Sources")
                    .font(.largeTitle)
                    .bold()
                Spacer()
                Button {
                    receiver.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }

            if let error = receiver.lastError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            if receiver.sources.isEmpty {
                VStack(spacing: 16) {
                    ProgressView()
                    Text(receiver.isScanning ? "Searching for NDI sources…" : "No NDI sources on this network.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(receiver.sources) { source in
                    Button(source.name) {
                        player.reset()
                        receiver.connect(to: source)
                    }
                }
                .listStyle(.plain)
            }
        }
        .padding(60)
    }
}

#Preview {
    ContentView()
}
