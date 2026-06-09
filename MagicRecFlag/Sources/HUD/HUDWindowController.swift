import AppKit
import SwiftUI

/// Manages the always-on-top floating HUD panel.
final class HUDWindowController {

    static let shared = HUDWindowController()

    private var panel: NSPanel?
    private var hostingView: NSView?
    private let hudState = HUDState()

    // MARK: – Public

    func show() {
        if panel != nil { panel?.orderFront(nil); return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 140, height: 60),
            styleMask: [.nonactivatingPanel, .titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Magic Rec Flag"
        panel.level = .floating                    // always on top
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden

        let hosting = NSHostingView(rootView: HUDView().environmentObject(hudState))
        panel.contentView = hosting
        hostingView = hosting

        // Position: top-right corner of main screen
        if let screen = NSScreen.main {
            let x = screen.visibleFrame.maxX - 160
            let y = screen.visibleFrame.maxY - 80
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
}

// MARK: – HUD observable state

final class HUDState: ObservableObject {
    @Published var isRecording: Bool = false
}

// MARK: – HUD SwiftUI view

struct HUDView: View {
    @EnvironmentObject var hudState: HUDState

    private var label: String { hudState.isRecording ? "● REC" : "STBY" }
    private var bg: Color     { hudState.isRecording ? .red : Color(white: 0.15) }
    private var fg: Color     { .white }

    var body: some View {
        Text(label)
            .font(.system(size: 20, weight: .black, design: .monospaced))
            .foregroundColor(fg)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .frame(minWidth: 110)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(bg)
                    .shadow(color: hudState.isRecording ? .red.opacity(0.6) : .clear,
                            radius: 8)
            )
            .animation(.easeInOut(duration: 0.2), value: hudState.isRecording)
    }
}
