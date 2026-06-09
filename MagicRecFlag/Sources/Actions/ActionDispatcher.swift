import AppKit
import CoreGraphics

/// Foregrounds the target application and injects the appropriate keyboard shortcut.
final class ActionDispatcher {

    static let shared = ActionDispatcher()

    private var pendingStop: DispatchWorkItem?

    // MARK: – Public triggers

    func triggerRecord() {
        // Cancel any queued stop — the signal came back before the delay elapsed
        pendingStop?.cancel()
        pendingStop = nil
        AppState.shared.isRecording = true
        HUDWindowController.shared.setState(.recording)
        performAction(hotkey: AppState.shared.recordHotkey)
    }

    func triggerStop() {
        let work = DispatchWorkItem { [weak self] in
            AppState.shared.isRecording = false
            HUDWindowController.shared.setState(.standby)
            self?.performAction(hotkey: AppState.shared.stopHotkey)
        }
        pendingStop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    // MARK: – Core action

    private func performAction(hotkey: HotkeyDefinition) {
        guard let url = AppState.shared.targetAppURL else { return }

        // 1. Launch or foreground the target application
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.hides = false

        NSWorkspace.shared.openApplication(at: url, configuration: config) { [weak self] app, error in
            if let error = error {
                print("[ActionDispatcher] Could not open app: \(error)")
                return
            }
            // 2. Short delay to let the app come to front, then send key
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self?.sendKeyEvent(hotkey: hotkey)
            }
        }
    }

    // MARK: – CGEvent keyboard injection

    private func sendKeyEvent(hotkey: HotkeyDefinition) {
        guard hotkey.isValid else { return }

        guard AXIsProcessTrusted() else {
            print("[ActionDispatcher] Accessibility not granted — cannot inject keystrokes.")
            return
        }

        let flags = cgFlags(from: hotkey.modifiers)

        // Key down
        if let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: hotkey.keyCode, keyDown: true) {
            keyDown.flags = flags
            keyDown.post(tap: .cghidEventTap)
        }

        // Key up (small delay)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: hotkey.keyCode, keyDown: false) {
                keyUp.flags = flags
                keyUp.post(tap: .cghidEventTap)
            }
        }
    }

    // MARK: – Modifier flag conversion

    private func cgFlags(from nsFlags: NSEvent.ModifierFlags) -> CGEventFlags {
        var flags: CGEventFlags = []
        if nsFlags.contains(.command) { flags.insert(.maskCommand) }
        if nsFlags.contains(.option)  { flags.insert(.maskAlternate) }
        if nsFlags.contains(.control) { flags.insert(.maskControl) }
        if nsFlags.contains(.shift)   { flags.insert(.maskShift) }
        return flags
    }
}
