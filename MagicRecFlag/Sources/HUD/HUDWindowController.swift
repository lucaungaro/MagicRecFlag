import AppKit
import SwiftUI

final class HUDWindowController {

    static let shared = HUDWindowController()

    private var panel: NSPanel?
    private var hostingView: NSView?
    private let hudState = HUDState()

    // MARK: – Public

    func show() {
        if panel != nil { panel?.orderFront(nil); return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 90),
            // .titled is needed for isMovableByWindowBackground; .closable omitted to hide the red button
            styleMask: [.nonactivatingPanel, .titled],
            backing: .buffered,
            defer: false
        )
        panel.title = ""
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden

        // Explicitly hide all traffic-light buttons
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        hudState.onStop = { [weak self] in self?.stopLiveMode() }

        let hosting = NSHostingView(rootView: HUDView().environmentObject(hudState))
        panel.contentView = hosting
        hostingView = hosting

        // Position: top-right corner of main screen
        if let screen = NSScreen.main {
            let x = screen.visibleFrame.maxX - 180
            let y = screen.visibleFrame.maxY - 100
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFront(nil)
        self.panel = panel
    }

    func hide() {
        panel?.close()
        panel = nil
    }

    func setState(_ state: CaptureEngine.RecordingState) {
        DispatchQueue.main.async { [weak self] in
            self?.hudState.isRecording = (state == .recording)
        }
    }

    // MARK: – Stop live mode

    private func stopLiveMode() {
        CaptureEngine.shared.stop()
        AppState.shared.isRecording = false
        AppState.shared.isLiveMode = false
        hide()
        // Restore the setup window
        NSApp.windows.first { !($0 is NSPanel) }?.makeKeyAndOrderFront(nil)
    }
}

// MARK: – HUD observable state

final class HUDState: ObservableObject {
    @Published var isRecording: Bool = false
    var onStop: (() -> Void)?
}

// MARK: – HUD SwiftUI view

struct HUDView: View {
    @EnvironmentObject var hudState: HUDState

    private var label: String { hudState.isRecording ? "● REC" : "STBY" }
    private var bg: Color     { hudState.isRecording ? .red : Color(white: 0.15) }

    var body: some View {
        VStack(spacing: 8) {
            Text(label)
                .font(.system(size: 20, weight: .black, design: .monospaced))
                .foregroundColor(.white)
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 4)
                .frame(minWidth: 120)

            Button(action: { hudState.onStop?() }) {
                Text("■ Stop")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.15))
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 10)
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(bg)
                .shadow(color: hudState.isRecording ? .red.opacity(0.6) : .clear, radius: 8)
        )
        .animation(.easeInOut(duration: 0.2), value: hudState.isRecording)
    }
}
