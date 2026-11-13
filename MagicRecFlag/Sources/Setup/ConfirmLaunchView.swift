import SwiftUI

struct ConfirmLaunchView: View {
    @EnvironmentObject var state: AppState
    let onLaunch: () -> Void

    var body: some View {
        // Compact enough to fit between the step bar and the bottom bar,
        // including the badge option and the Accessibility warning.
        VStack(spacing: 18) {
            Spacer(minLength: 0)

            VStack(spacing: 6) {
                HStack(spacing: 10) {
                    Image(systemName: "record.circle")
                        .font(.system(size: 28))
                        .foregroundColor(.red)
                    Text("Ready to go LIVE")
                        .font(.title).bold()
                }
                Text("Review your configuration below, then click Launch.")
                    .foregroundColor(.secondary)
            }

            // Summary
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
                summaryRow("Capture Device", state.selectedDeviceDisplayName)
                summaryRow("Detection Region",
                    String(format: "X %.0f%%  Y %.0f%%  W %.0f%%  H %.0f%%",
                           state.roiRect.minX * 100, state.roiRect.minY * 100,
                           state.roiRect.width * 100, state.roiRect.height * 100))
                summaryRow("Target App", state.targetAppName)
                summaryRow("Record shortcuts", state.recordHotkeys.sequenceDisplay)
                summaryRow("Stop shortcuts", state.stopHotkeys.sequenceDisplay)
                summaryRow("Red threshold", "\(Int(state.redThreshold * 100))% of ROI pixels")
            }
            .padding(16)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)

            VStack(spacing: 4) {
                Toggle("Also show floating badge", isOn: $state.showFloatingBadge)
                Text("Stays visible when a full-screen app hides the menu bar.")
                    .font(.caption).foregroundColor(.secondary)
            }

            if !AXIsProcessTrusted() {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text("Accessibility access is off: Record / Stop shortcuts cannot be sent.")
                    Button("Open Settings") { ActionDispatcher.openAccessibilitySettings() }
                }
                .font(.callout)
            }

            Button(action: onLaunch) {
                Label("Launch Live Mode", systemImage: "play.fill")
                    .font(.headline)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.red)
            .disabled(!state.isFullyConfigured)

            Spacer(minLength: 0)
        }
        .padding(24)
    }

    @ViewBuilder
    private func summaryRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundColor(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .fontWeight(.medium)
                .gridColumnAlignment(.leading)
        }
    }
}
