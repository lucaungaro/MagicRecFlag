import AVFoundation
import AppKit
import Combine

/// Central observable state for the entire application.
final class AppState: ObservableObject {

    static let shared = AppState()

    // MARK: – Setup configuration

    /// The selected AVCaptureDevice (AJA, Blackmagic, FaceTime, etc.)
    @Published var selectedDevice: AVCaptureDevice? = nil

    /// Normalised ROI rectangle in the capture frame (values 0…1)
    @Published var roiRect: CGRect = CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)

    /// The external application to foreground/launch
    @Published var targetAppURL: URL? = nil
    @Published var targetAppName: String = "None selected"

    /// Keyboard shortcut for "start recording"
    @Published var recordHotkey: HotkeyDefinition = HotkeyDefinition()

    /// Keyboard shortcut for "stop recording"
    @Published var stopHotkey: HotkeyDefinition = HotkeyDefinition()

    // MARK: – Live mode state

    @Published var isLiveMode: Bool = false
    @Published var isRecording: Bool = false

    // MARK: – Detection tuning

    /// Minimum fraction of ROI pixels that must be "red" to trigger
    @Published var redThreshold: Double = 0.15

    /// HSV hue range considered "red" (hue wraps, so we check 0…redHueWidth and (1-redHueWidth)…1)
    @Published var redHueWidth: Double = 0.08

    /// Minimum saturation for a pixel to be considered coloured (not grey/white)
    @Published var minSaturation: Double = 0.45

    /// Minimum brightness for a pixel to count
    @Published var minBrightness: Double = 0.25

    // MARK: – Computed helpers

    var isFullyConfigured: Bool {
        selectedDevice != nil &&
        targetAppURL != nil &&
        recordHotkey.isValid &&
        stopHotkey.isValid
    }
}

// MARK: – HotkeyDefinition

struct HotkeyDefinition: Equatable {
    var keyCode: UInt16 = 0
    var modifiers: NSEvent.ModifierFlags = []
    var displayString: String = ""

    var isValid: Bool { !displayString.isEmpty }
}
