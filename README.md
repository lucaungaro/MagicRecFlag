# Magic Rec Flag

A macOS utility that monitors a rectangle in a video capture device feed for a **red tally signal**, then automatically triggers record/stop in an external application via keyboard shortcut.

## Requirements

- macOS 13.0 (Ventura) or later
- Xcode 15 or later
- AJA, Blackmagic, or any AVFoundation-compatible capture device
- Accessibility permission (for keyboard injection)
- Camera permission

## Project Structure

```
MagicRecFlag/
├── Sources/
│   ├── App/
│   │   ├── MagicRecFlagApp.swift      ← @main entry, SwiftUI scene
│   │   └── AppDelegate.swift          ← Lifecycle, permissions
│   ├── Models/
│   │   └── AppState.swift             ← Central ObservableObject state
│   ├── Setup/
│   │   ├── SetupContainerView.swift   ← 5-step wizard shell
│   │   ├── DevicePickerView.swift     ← Step 1: capture device
│   │   ├── ROISelectorView.swift      ← Step 2: drag ROI on live preview
│   │   ├── AppPickerView.swift        ← Step 3: choose target app
│   │   ├── HotkeySetupView.swift      ← Step 4: record shortcut keys
│   │   └── ConfirmLaunchView.swift    ← Step 5: review & launch
│   ├── Capture/
│   │   └── CaptureEngine.swift        ← AVCaptureSession + frame dispatch
│   ├── Detection/
│   │   └── ROIAnalyzer.swift          ← HSV red-pixel analyser
│   ├── HUD/
│   │   └── HUDWindowController.swift  ← Floating STBY/REC panel
│   └── Actions/
│       └── ActionDispatcher.swift     ← NSWorkspace + CGEvent injection
└── Resources/
    ├── Info.plist
    └── MagicRecFlag.entitlements
```

## Opening in Xcode

```bash
open ~/Dev/MagicRecFlag/MagicRecFlag.xcodeproj
```

Then in Xcode:
1. Select the **Magic Rec Flag** target
2. Under **Signing & Capabilities**, set your Team
3. Press **⌘R** to build and run

## First Launch

1. Grant **Camera** access when prompted
2. Go to **System Settings → Privacy & Security → Accessibility** and enable Magic Rec Flag
3. Complete the 5-step setup wizard
4. Click **Launch Live Mode**

## How Detection Works

The `ROIAnalyzer` converts each video frame's ROI pixels from BGR to **HSV** colour space and counts pixels whose:
- **Hue** falls in the red band (0–8° or 352–360°, configurable)
- **Saturation** ≥ 45% (not grey/white)
- **Brightness** ≥ 25% (not black)

If the fraction of red pixels exceeds the threshold (default 15%), and this persists for 3 consecutive frames, the record trigger fires.

## Tuning

The **Detection Region** setup step has a sensitivity slider. If you get false triggers:
- Raise the red threshold (e.g., 25–30%)
- Increase `minSaturation` in AppState for purer-red detection

## Notes

- The `.entitlements` file has `app-sandbox = false` because CGEvent keystroke injection requires it. The app should **not** be submitted to the Mac App Store in this form.
- For App Store distribution, consider using Apple's Accessibility API or a different IPC mechanism.
