import AVFoundation
import AppKit
import Combine

final class AppState: ObservableObject {

    static let shared = AppState()

    // MARK: – Device selection
    // Exactly one of these is non-nil when a device is chosen.

    /// Set when the user picks an AVFoundation (webcam / NDI virtual camera) device.
    @Published var selectedDevice: AVCaptureDevice? = nil

    /// Set when the user picks a native DeckLink device.
    @Published var selectedDLDevice: DLDevice? = nil

    var hasSelectedDevice: Bool { selectedDevice != nil || selectedDLDevice != nil }

    var selectedDeviceDisplayName: String {
        selectedDevice?.localizedName ?? selectedDLDevice?.name ?? "None selected"
    }

    // MARK: – Setup configuration

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
        hasSelectedDevice &&
        targetAppURL != nil &&
        recordHotkey.isValid &&
        stopHotkey.isValid
    }

    // MARK: – Persistence

    func saveToDefaults() {
        let d = UserDefaults.standard

        // Device
        if let dl = selectedDLDevice {
            d.set("decklink",  forKey: "selectedDeviceType")
            d.set(dl.name,     forKey: "selectedDLDeviceName")
        } else if let av = selectedDevice {
            d.set("avfoundation",  forKey: "selectedDeviceType")
            d.set(av.uniqueID,     forKey: "selectedDeviceID")
        }

        // Target app
        if let url = targetAppURL {
            d.set(url.path,    forKey: "targetAppPath")
            d.set(targetAppName, forKey: "targetAppName")
        }

        // ROI
        d.set(roiRect.minX,   forKey: "roiMinX")
        d.set(roiRect.minY,   forKey: "roiMinY")
        d.set(roiRect.width,  forKey: "roiWidth")
        d.set(roiRect.height, forKey: "roiHeight")

        // Hotkeys
        d.set(Int(recordHotkey.keyCode),            forKey: "recordKeyCode")
        d.set(Int(recordHotkey.modifiers.rawValue),  forKey: "recordModifiers")
        d.set(recordHotkey.displayString,            forKey: "recordDisplayString")
        d.set(Int(stopHotkey.keyCode),               forKey: "stopKeyCode")
        d.set(Int(stopHotkey.modifiers.rawValue),    forKey: "stopModifiers")
        d.set(stopHotkey.displayString,              forKey: "stopDisplayString")

        // Detection tuning
        d.set(redThreshold,   forKey: "redThreshold")
        d.set(redHueWidth,    forKey: "redHueWidth")
        d.set(minSaturation,  forKey: "minSaturation")
        d.set(minBrightness,  forKey: "minBrightness")
    }

    func loadFromDefaults() {
        let d = UserDefaults.standard

        // Device
        let deviceType = d.string(forKey: "selectedDeviceType") ?? "avfoundation"
        if deviceType == "decklink" {
            if let name = d.string(forKey: "selectedDLDeviceName"),
               DLDeviceEnumerator.isAvailable() {
                selectedDLDevice = DLDeviceEnumerator.availableDevices()
                    .first { $0.name == name }
            }
        } else {
            if let uid = d.string(forKey: "selectedDeviceID") {
                let deviceTypes: [AVCaptureDevice.DeviceType]
                if #available(macOS 14.0, *) {
                    deviceTypes = [.external, .builtInWideAngleCamera, .continuityCamera]
                } else {
                    deviceTypes = [.externalUnknown, .builtInWideAngleCamera]
                }
                let session = AVCaptureDevice.DiscoverySession(
                    deviceTypes: deviceTypes,
                    mediaType: .video, position: .unspecified)
                selectedDevice = session.devices.first { $0.uniqueID == uid }
            }
        }

        // Target app
        if let path = d.string(forKey: "targetAppPath") {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path) {
                targetAppURL  = url
                targetAppName = d.string(forKey: "targetAppName")
                    ?? url.deletingPathExtension().lastPathComponent
            }
        }

        // ROI
        let w = d.double(forKey: "roiWidth"), h = d.double(forKey: "roiHeight")
        if w > 0 && h > 0 {
            roiRect = CGRect(x: d.double(forKey: "roiMinX"), y: d.double(forKey: "roiMinY"),
                             width: w, height: h)
        }

        // Hotkeys
        if d.object(forKey: "recordKeyCode") != nil {
            recordHotkey = HotkeyDefinition(
                keyCode:       UInt16(d.integer(forKey: "recordKeyCode")),
                modifiers:     NSEvent.ModifierFlags(rawValue: UInt(d.integer(forKey: "recordModifiers"))),
                displayString: d.string(forKey: "recordDisplayString") ?? "")
        }
        if d.object(forKey: "stopKeyCode") != nil {
            stopHotkey = HotkeyDefinition(
                keyCode:       UInt16(d.integer(forKey: "stopKeyCode")),
                modifiers:     NSEvent.ModifierFlags(rawValue: UInt(d.integer(forKey: "stopModifiers"))),
                displayString: d.string(forKey: "stopDisplayString") ?? "")
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
