import AppKit
import SwiftUI

/// Live-mode UI: a STBY / REC item in the menu bar (always), plus an optional
/// floating badge for when the menu bar is hidden (e.g. a full-screen recorder).
final class HUDWindowController: NSObject {

    static let shared = HUDWindowController()

    private var statusItem: NSStatusItem?
    private var floatingBadgeMenuItem: NSMenuItem?
    private var warningMenuItem: NSMenuItem?
    /// Set when a shortcut could not be sent; shown as ⚠ in the menu bar.
    private var shortcutWarning: String?
    private var panel: NSPanel?
    private var setupWindow: NSWindow?
    private let hudState = HUDState()

    // MARK: – Public

    /// Enters live mode: hides the setup window and the Dock icon, shows the indicators.
    func show() {
        guard statusItem == nil else { return }

        // Remember the setup window before any status-bar / panel window exists,
        // so it can be restored exactly on stop.
        setupWindow = NSApp.windows.first { $0.isVisible && !($0 is NSPanel) }
        setupWindow?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)

        hudState.isRecording = AppState.shared.isRecording
        hudState.onStop = { [weak self] in self?.stopLiveMode() }

        showStatusItem()
        if AppState.shared.showFloatingBadge { showPanel() }
    }

    func setState(_ state: CaptureEngine.RecordingState) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hudState.isRecording = (state == .recording)
            self.updateStatusItemTitle()
        }
    }

    /// Flags in the menu bar that a Record / Stop shortcut was not sent.
    func reportShortcutFailure(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.shortcutWarning = message
            self.warningMenuItem?.title = "⚠ \(message) — Open Settings…"
            self.warningMenuItem?.isHidden = false
            self.updateStatusItemTitle()
        }
    }

    // MARK: – Menu bar item

    private func showStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        let warning = NSMenuItem(title: "", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        warning.target   = self
        warning.isHidden = true
        menu.addItem(warning)
        warningMenuItem = warning

        let source = NSMenuItem(title: "Watching: \(AppState.shared.selectedDeviceDisplayName)",
                                action: nil, keyEquivalent: "")
        source.isEnabled = false
        menu.addItem(source)
        menu.addItem(.separator())

        let badge = NSMenuItem(title: "Show Floating Badge",
                               action: #selector(toggleFloatingBadge), keyEquivalent: "")
        badge.target = self
        badge.state  = AppState.shared.showFloatingBadge ? .on : .off
        menu.addItem(badge)
        floatingBadgeMenuItem = badge
        menu.addItem(.separator())

        let stop = NSMenuItem(title: "■ Stop Live Mode", action: #selector(stopFromMenu), keyEquivalent: "")
        stop.target = self
        menu.addItem(stop)

        item.menu = menu
        statusItem = item
        updateStatusItemTitle()
    }

    private func updateStatusItemTitle() {
        guard let button = statusItem?.button else { return }
        let recording = hudState.isRecording
        let label = recording ? "● REC" : "STBY"
        button.attributedTitle = NSAttributedString(
            string: shortcutWarning == nil ? label : "⚠ " + label,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .black),
                // labelColor follows the menu bar's own appearance: white on a dark
                // menu bar, black on a light one.
                .foregroundColor: recording ? NSColor.systemRed : NSColor.labelColor,
            ])
    }

    @objc private func toggleFloatingBadge() {
        let show = !AppState.shared.showFloatingBadge
        AppState.shared.showFloatingBadge = show
        UserDefaults.standard.set(show, forKey: "showFloatingBadge")
        floatingBadgeMenuItem?.state = show ? .on : .off
        if show { showPanel() } else { hidePanel() }
    }

    @objc private func stopFromMenu() { stopLiveMode() }

    @objc private func openAccessibilitySettings() { ActionDispatcher.openAccessibilitySettings() }

    // MARK: – Floating badge

    private func showPanel() {
        if panel != nil { panel?.orderFront(nil); return }

        // Borderless: the window is exactly the badge, with no invisible title bar
        // above it, and AppKit does not keep it below the menu bar.
        let hosting = NSHostingView(rootView: HUDView().environmentObject(hudState))
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = hosting

        // Default position: just under the menu bar, top-right corner of the main
        // screen; then wherever the user last dragged it.
        if let screen = NSScreen.main {
            let margin: CGFloat = 8
            let x = screen.visibleFrame.maxX - panel.frame.width - margin
            let y = screen.visibleFrame.maxY - panel.frame.height - margin
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        panel.setFrameAutosaveName("MagicRecFlagBadge")

        panel.orderFront(nil)
        self.panel = panel
    }

    private func hidePanel() {
        panel?.close()
        panel = nil
    }

    // MARK: – Stop live mode

    private func stopLiveMode() {
        CaptureEngine.shared.stop()
        AppState.shared.isRecording = false
        AppState.shared.isLiveMode = false
        hudState.isRecording = false

        hidePanel()
        if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
        statusItem = nil
        floatingBadgeMenuItem = nil
        warningMenuItem = nil
        shortcutWarning = nil

        // Restore the Dock icon and the setup window
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        setupWindow?.makeKeyAndOrderFront(nil)
        setupWindow = nil
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
