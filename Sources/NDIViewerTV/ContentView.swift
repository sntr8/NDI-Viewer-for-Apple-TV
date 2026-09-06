import SwiftUI

struct ContentView: View {
    @StateObject private var receiver = NDIReceiver()

    var body: some View {
        ZStack {
            if receiver.isConnected {
                VideoDisplayView(receiver: receiver)
                    .ignoresSafeArea()
                    .onExitCommand {
                        receiver.disconnect()
                    }
                    .overlay(alignment: .top) {
                        if let name = receiver.connectedSourceName {
                            Text(name)
                                .font(.caption)
                                .padding(8)
                                .background(.black.opacity(0.5))
                                .clipShape(Capsule())
                                .padding(.top, 40)
                        }
                    }
            } else {
                sourceList
            }
        }
        .onAppear { receiver.start() }
        .onDisappear { receiver.stop() }
    }

    private var sourceList: some View {
        VStack(spacing: 24) {
            Text("NDI Viewer")
                .font(.largeTitle)
                .bold()

            if let error = receiver.lastError {
                Text(error)
                    .foregroundStyle(.red)
            }

            if receiver.sources.isEmpty {
                ProgressView("Searching for NDI sources…")
            } else {
                List(receiver.sources) { source in
                    Button(source.name) {
                        receiver.connect(to: source)
                    }
                }
            }
        }
        .padding(60)
    }
}

#Preview {
    ContentView()
}
