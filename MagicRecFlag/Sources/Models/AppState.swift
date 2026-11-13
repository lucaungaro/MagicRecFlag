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

    /// Set when the user picks an NDI source received natively over the network.
    @Published var selectedNDISource: NDISource? = nil

    var hasSelectedDevice: Bool {
        selectedDevice != nil || selectedDLDevice != nil || selectedNDISource != nil
    }

    var selectedDeviceDisplayName: String {
        selectedDevice?.localizedName ?? selectedDLDevice?.name
            ?? selectedNDISource?.name ?? "None selected"
    }

    // MARK: – Setup configuration

    @Published var roiRect: CGRect = CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
    @Published var targetAppURL: URL? = nil
    @Published var targetAppName: String = "None selected"
    /// Shortcuts sent in order when REC / STBY is detected (at least one slot).
    @Published var recordHotkeys: [HotkeyDefinition] = [HotkeyDefinition()]
    @Published var stopHotkeys:   [HotkeyDefinition] = [HotkeyDefinition()]

    // MARK: – Live mode state

    @Published var isLiveMode: Bool = false
    @Published var isRecording: Bool = false
    /// Live mode always shows STBY / REC in the menu bar; this adds the floating
    /// badge, which stays visible when a full-screen app hides the menu bar.
    @Published var showFloatingBadge: Bool = false

    // MARK: – Detection tuning

    @Published var redThreshold: Double = 0.15
    @Published var redHueWidth: Double = 0.08
    @Published var minSaturation: Double = 0.45
    @Published var minBrightness: Double = 0.25

    // MARK: – Computed helpers

    var isFullyConfigured: Bool {
        hasSelectedDevice &&
        targetAppURL != nil &&
        hasValidShortcuts
    }

    var hasValidShortcuts: Bool {
        recordHotkeys.contains { $0.isValid } && stopHotkeys.contains { $0.isValid }
    }

    // MARK: – Persistence

    func saveToDefaults() {
        let d = UserDefaults.standard

        // Device
        if let dl = selectedDLDevice {
            d.set("decklink",  forKey: "selectedDeviceType")
            d.set(dl.name,     forKey: "selectedDLDeviceName")
        } else if let ndi = selectedNDISource {
            d.set("ndi",     forKey: "selectedDeviceType")
            d.set(ndi.name,  forKey: "selectedNDISourceName")
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
        d.set(recordHotkeys.filter(\.isValid).map(\.dictionary), forKey: "recordHotkeys")
        d.set(stopHotkeys.filter(\.isValid).map(\.dictionary),   forKey: "stopHotkeys")

        // Detection tuning
        d.set(redThreshold,   forKey: "redThreshold")
        d.set(redHueWidth,    forKey: "redHueWidth")
        d.set(minSaturation,  forKey: "minSaturation")
        d.set(minBrightness,  forKey: "minBrightness")

        // Live mode
        d.set(showFloatingBadge, forKey: "showFloatingBadge")
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
        } else if deviceType == "ndi" {
            // NDI connects by name, so no discovery round-trip is needed here;
            // the receiver simply waits until the source is on the network.
            if let name = d.string(forKey: "selectedNDISourceName"),
               NDISourceFinder.isAvailable() {
                selectedNDISource = NDISource(name: name)
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
        recordHotkeys = Self.loadHotkeys(d, listKey: "recordHotkeys", legacyPrefix: "record")
        stopHotkeys   = Self.loadHotkeys(d, listKey: "stopHotkeys",   legacyPrefix: "stop")

        // Detection tuning
        if d.object(forKey: "redThreshold")  != nil { redThreshold  = d.double(forKey: "redThreshold") }
        if d.object(forKey: "redHueWidth")   != nil { redHueWidth   = d.double(forKey: "redHueWidth") }
        if d.object(forKey: "minSaturation") != nil { minSaturation = d.double(forKey: "minSaturation") }
        if d.object(forKey: "minBrightness") != nil { minBrightness = d.double(forKey: "minBrightness") }

        // Live mode
        showFloatingBadge = d.bool(forKey: "showFloatingBadge")
    }
}

extension AppState {
    /// Reads a shortcut list, falling back to the single shortcut saved by
    /// earlier versions ("recordKeyCode", "recordModifiers", …).
    fileprivate static func loadHotkeys(_ d: UserDefaults, listKey: String,
                                        legacyPrefix: String) -> [HotkeyDefinition] {
        if let list = d.array(forKey: listKey) as? [[String: Any]] {
            let hotkeys = list.compactMap(HotkeyDefinition.init(dictionary:))
            if !hotkeys.isEmpty { return hotkeys }
        }
        if d.object(forKey: legacyPrefix + "KeyCode") != nil {
            return [HotkeyDefinition(
                keyCode:       UInt16(d.integer(forKey: legacyPrefix + "KeyCode")),
                modifiers:     NSEvent.ModifierFlags(rawValue: UInt(d.integer(forKey: legacyPrefix + "Modifiers"))),
                displayString: d.string(forKey: legacyPrefix + "DisplayString") ?? "")]
        }
        return [HotkeyDefinition()]
    }
}

// MARK: – HotkeyDefinition

struct HotkeyDefinition: Equatable {
    var keyCode: UInt16 = 0
    var modifiers: NSEvent.ModifierFlags = []
    var displayString: String = ""
    var isValid: Bool { !displayString.isEmpty }
}

extension HotkeyDefinition {
    var dictionary: [String: Any] {
        ["keyCode": Int(keyCode), "modifiers": Int(modifiers.rawValue), "display": displayString]
    }

    init?(dictionary d: [String: Any]) {
        guard let code = d["keyCode"] as? Int, let display = d["display"] as? String,
              !display.isEmpty else { return nil }
        self.init(keyCode: UInt16(code),
                  modifiers: NSEvent.ModifierFlags(rawValue: UInt(d["modifiers"] as? Int ?? 0)),
                  displayString: display)
    }
}

extension Array where Element == HotkeyDefinition {
    /// "⌥R → ⌘S", for summaries and logs.
    var sequenceDisplay: String {
        filter(\.isValid).map(\.displayString).joined(separator: " → ")
    }
}
