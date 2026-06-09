import AppKit
import AVFoundation

class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppState.shared.loadFromDefaults()
        requestPermissions()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // If in live mode, keep running even if setup window closes
        return !AppState.shared.isLiveMode
    }

    // MARK: – Permissions

    private func requestPermissions() {
        // Camera access
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if !granted {
                    DispatchQueue.main.async { self.showPermissionAlert(for: "Camera") }
                }
            }
        case .denied, .restricted:
            showPermissionAlert(for: "Camera")
        default:
            break
        }

        // Accessibility access (required for CGEvent injection)
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
    }

    private func showPermissionAlert(for permission: String) {
        let alert = NSAlert()
        alert.messageText = "\(permission) Access Required"
        alert.informativeText = "Magic Rec Flag needs \(permission) access to function. Please enable it in System Settings → Privacy & Security."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Quit")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
        } else {
            NSApp.terminate(nil)
        }
    }
}
