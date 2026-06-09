import SwiftUI

struct ConfirmLaunchView: View {
    @EnvironmentObject var state: AppState
    let onLaunch: () -> Void

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "record.circle")
                .font(.system(size: 64))
                .foregroundColor(.red)

            VStack(spacing: 8) {
                Text("Ready to go LIVE")
                    .font(.title).bold()
                Text("Review your configuration below, then click Launch.")
                    .foregroundColor(.secondary)
            }

            // Summary
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 10) {
                summaryRow("Capture Device", state.selectedDevice?.localizedName ?? "—")
                summaryRow("Detection Region",
                    String(format: "X %.0f%%  Y %.0f%%  W %.0f%%  H %.0f%%",
                           state.roiRect.minX * 100, state.roiRect.minY * 100,
                           state.roiRect.width * 100, state.roiRect.height * 100))
                summaryRow("Target App", state.targetAppName)
                summaryRow("Record shortcut", state.recordHotkey.displayString)
                summaryRow("Stop shortcut", state.stopHotkey.displayString)
                summaryRow("Red threshold", "\(Int(state.redThreshold * 100))% of ROI pixels")
            }
            .padding(20)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)

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

            Spacer()
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
