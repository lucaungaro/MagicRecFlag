import AVFoundation
import AppKit
import Combine

final class AppState: ObservableObject {

    static let shared = AppState()

    // MARK: – Setup configuration

    @Published var selectedDevice: AVCaptureDevice? = nil
    @Published var roiRect: CGRect = CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
    @Published var targetAppURL: URL? = nil
    @Published var targetAppName: String = "None selected"
    @Published var recordHotkey: HotkeyDefinition = HotkeyDefinition()
    @Published var stopHotkey: HotkeyDefinition = HotkeyDefinition()

    // MARK: – Live mode state

    @Published var isLiveMode: Bool = false
    @Published var isRecording: Bool = false

    // MARK: – Detection tuning

    @Published var redThreshold: Double = 0.15
    @Published var redHueWidth: Double = 0.08
    @Published var minSaturation: Double = 0.45
    @Published var minBrightness: Double = 0.25

    // MARK: – Computed helpers

    var isFullyConfigured: Bool {
        selectedDevice != nil &&
        targetAppURL != nil &&
        recordHotkey.isValid &&
        stopHotkey.isValid
    }

    // MARK: – Persistence

    func saveToDefaults() {
        let d = UserDefaults.standard
        d.set(selectedDevice?.uniqueID, forKey: "selectedDeviceID")
        if let url = targetAppURL {
            d.set(url.path, forKey: "targetAppPath")
            d.set(targetAppName, forKey: "targetAppName")
        }
        d.set(roiRect.minX, forKey: "roiMinX")
        d.set(roiRect.minY, forKey: "roiMinY")
        d.set(roiRect.width,  forKey: "roiWidth")
        d.set(roiRect.height, forKey: "roiHeight")
        d.set(Int(recordHotkey.keyCode),          forKey: "recordKeyCode")
        d.set(Int(recordHotkey.modifiers.rawValue), forKey: "recordModifiers")
        d.set(recordHotkey.displayString,          forKey: "recordDisplayString")
        d.set(Int(stopHotkey.keyCode),             forKey: "stopKeyCode")
        d.set(Int(stopHotkey.modifiers.rawValue),  forKey: "stopModifiers")
        d.set(stopHotkey.displayString,            forKey: "stopDisplayString")
        d.set(redThreshold,   forKey: "redThreshold")
        d.set(redHueWidth,    forKey: "redHueWidth")
        d.set(minSaturation,  forKey: "minSaturation")
        d.set(minBrightness,  forKey: "minBrightness")
    }

    func loadFromDefaults() {
        let d = UserDefaults.standard

        // Capture device — match by unique ID
        if let deviceID = d.string(forKey: "selectedDeviceID") {
            let session = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.externalUnknown, .builtInWideAngleCamera],
                mediaType: .video,
                position: .unspecified
            )
            selectedDevice = session.devices.first { $0.uniqueID == deviceID }
        }

        // Target app
        if let path = d.string(forKey: "targetAppPath") {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path) {
                targetAppURL = url
                targetAppName = d.string(forKey: "targetAppName")
                    ?? url.deletingPathExtension().lastPathComponent
            }
        }

        // ROI
        let w = d.double(forKey: "roiWidth")
        let h = d.double(forKey: "roiHeight")
        if w > 0 && h > 0 {
            roiRect = CGRect(
                x: d.double(forKey: "roiMinX"),
                y: d.double(forKey: "roiMinY"),
                width: w, height: h
            )
        }

        // Hotkeys
        if d.object(forKey: "recordKeyCode") != nil {
            recordHotkey = HotkeyDefinition(
                keyCode: UInt16(d.integer(forKey: "recordKeyCode")),
                modifiers: NSEvent.ModifierFlags(rawValue: UInt(d.integer(forKey: "recordModifiers"))),
                displayString: d.string(forKey: "recordDisplayString") ?? ""
            )
        }
        if d.object(forKey: "stopKeyCode") != nil {
            stopHotkey = HotkeyDefinition(
                keyCode: UInt16(d.integer(forKey: "stopKeyCode")),
                modifiers: NSEvent.ModifierFlags(rawValue: UInt(d.integer(forKey: "stopModifiers"))),
                displayString: d.string(forKey: "stopDisplayString") ?? ""
            )
        }

        // Detection tuning
        if d.object(forKey: "redThreshold")  != nil { redThreshold  = d.double(forKey: "redThreshold") }
        if d.object(forKey: "redHueWidth")   != nil { redHueWidth   = d.double(forKey: "redHueWidth") }
        if d.object(forKey: "minSaturation") != nil { minSaturation = d.double(forKey: "minSaturation") }
        if d.object(forKey: "minBrightness") != nil { minBrightness = d.double(forKey: "minBrightness") }
    }
}

// MARK: – HotkeyDefinition

struct HotkeyDefinition: Equatable {
    var keyCode: UInt16 = 0
    var modifiers: NSEvent.ModifierFlags = []
    var displayString: String = ""

    var isValid: Bool { !displayString.isEmpty }
}
