import SwiftUI

struct SetupContainerView: View {
    @EnvironmentObject var state: AppState
    @State private var currentStep: SetupStep = .device

    enum SetupStep: Int, CaseIterable {
        case device = 0
        case roi
        case targetApp
        case hotkeys
        case confirm

        var title: String {
            switch self {
            case .device:    return "1  Capture Device"
            case .roi:       return "2  Detection Region"
            case .targetApp: return "3  Target Application"
            case .hotkeys:   return "4  Keyboard Shortcuts"
            case .confirm:   return "5  Ready"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ──────────────────────────────────────────────
            HStack(spacing: 0) {
                ForEach(SetupStep.allCases, id: \.rawValue) { step in
                    stepPill(step)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider()

            // ── Page content ─────────────────────────────────────────
            Group {
                switch currentStep {
                case .device:    DevicePickerView()
                case .roi:       ROISelectorView()
                case .targetApp: AppPickerView()
                case .hotkeys:   HotkeySetupView()
                case .confirm:   ConfirmLaunchView(onLaunch: launchLiveMode)
                }
            }
            .frame(width: 680, height: 480)
            .animation(.easeInOut(duration: 0.25), value: currentStep)

            Divider()

            // ── Navigation bar ───────────────────────────────────────
            HStack {
                if currentStep.rawValue > 0 {
                    Button("← Back") {
                        currentStep = SetupStep(rawValue: currentStep.rawValue - 1)!
                    }
                }
                Spacer()
                if currentStep != .confirm {
                    Button("Next →") {
                        currentStep = SetupStep(rawValue: currentStep.rawValue + 1)!
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAdvance)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            // If we have a complete saved configuration, jump straight to the confirm step
            if state.isFullyConfigured {
                currentStep = .confirm
            }
        }
    }

    // MARK: – Step pill

    @ViewBuilder
    private func stepPill(_ step: SetupStep) -> some View {
        let active = step == currentStep
        let done   = step.rawValue < currentStep.rawValue
        HStack(spacing: 6) {
            Circle()
                .fill(done ? Color.green : (active ? Color.accentColor : Color.secondary.opacity(0.3)))
                .frame(width: 8, height: 8)
            Text(step.title)
                .font(.caption)
                .fontWeight(active ? .semibold : .regular)
                .foregroundColor(active ? .primary : .secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(active ? Color.accentColor.opacity(0.08) : Color.clear)
        .cornerRadius(6)
        if step != SetupStep.allCases.last {
            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(width: 16, height: 1)
        }
    }

    // MARK: – Logic

    private var canAdvance: Bool {
        switch currentStep {
        case .device:    return state.hasSelectedDevice
        case .roi:       return true
        case .targetApp: return state.targetAppURL != nil
        case .hotkeys:   return state.recordHotkey.isValid && state.stopHotkey.isValid
        case .confirm:   return false
        }
    }

    private func launchLiveMode() {
        state.saveToDefaults()
        state.isLiveMode = true
        HUDWindowController.shared.show()
        CaptureEngine.shared.start()
        // Hide (not close) so we can restore it when the user stops live mode
        NSApp.windows.first { !($0 is NSPanel) }?.orderOut(nil)
    }
}
