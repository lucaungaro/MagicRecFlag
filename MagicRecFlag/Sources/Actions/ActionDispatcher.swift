import AppKit
import CoreGraphics

/// Foregrounds the target application and injects the appropriate keyboard shortcut.
final class ActionDispatcher {

    static let shared = ActionDispatcher()

    // MARK: – Public triggers

    func triggerRecord() {
        NSLog("[ActionDispatcher] REC detected — sending Record shortcuts %@",
              AppState.shared.recordHotkeys.sequenceDisplay)
        AppState.shared.isRecording = true
        HUDWindowController.shared.setState(.recording)
        performAction(hotkeys: AppState.shared.recordHotkeys)
    }

    func triggerStop() {
        NSLog("[ActionDispatcher] STBY detected — sending Stop shortcuts %@",
              AppState.shared.stopHotkeys.sequenceDisplay)
        AppState.shared.isRecording = false
        HUDWindowController.shared.setState(.standby)
        performAction(hotkeys: AppState.shared.stopHotkeys)
    }

    // MARK: – Core action

    /// Pause between two shortcuts of a sequence, so the target app has handled
    /// the first one before the next arrives.
    private let sequenceInterval: TimeInterval = 0.25

    private func performAction(hotkeys: [HotkeyDefinition]) {
        let hotkeys = hotkeys.filter(\.isValid)
        guard let url = AppState.shared.targetAppURL else { return }

        // 1. Launch or foreground the target application
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.hides = false

        NSWorkspace.shared.openApplication(at: url, configuration: config) { [weak self] app, error in
            if let error = error {
                NSLog("[ActionDispatcher] Could not open %@: %@", url.path, "\(error)")
                HUDWindowController.shared.reportShortcutFailure("Could not open \(url.lastPathComponent)")
                return
            }
            // 2. Short delay to let the app settle, then send the keys to it in order
            guard let self else { return }
            for (i, hotkey) in hotkeys.enumerated() {
                let delay = 0.15 + Double(i) * self.sequenceInterval
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    self.sendKeyEvent(hotkey: hotkey, to: app)
                }
            }
        }
    }

    // MARK: – CGEvent keyboard injection

    /// Sends the shortcut straight to the target process when it is known.
    /// Posting to the HID tap only reaches whichever app is frontmost, and a
    /// background (menu bar) app cannot rely on bringing the recorder to front.
    private func sendKeyEvent(hotkey: HotkeyDefinition, to app: NSRunningApplication?) {
        guard hotkey.isValid else { return }

        guard AXIsProcessTrusted() else {
            NSLog("[ActionDispatcher] Accessibility not granted — shortcut NOT sent")
            HUDWindowController.shared.reportShortcutFailure("Accessibility access needed")
            return
        }
        let pid = app?.processIdentifier
        NSLog("[ActionDispatcher] posting %@ to %@ (pid %d); frontmost: %@",
              hotkey.displayString, app?.localizedName ?? "HID tap", pid ?? -1,
              NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")

        let flags = cgFlags(from: hotkey.modifiers)
        let post: (CGEvent) -> Void = { event in
            event.flags = flags
            if let pid { event.postToPid(pid) } else { event.post(tap: .cghidEventTap) }
        }

        // Key down
        if let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: hotkey.keyCode, keyDown: true) {
            post(keyDown)
        }

        // Key up (small delay)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: hotkey.keyCode, keyDown: false) {
                post(keyUp)
            }
        }
    }

    /// Opens System Settings → Privacy & Security → Accessibility.
    static func openAccessibilitySettings() {
        let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        NSWorkspace.shared.open(URL(string: url)!)
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
