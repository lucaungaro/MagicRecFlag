import SwiftUI
import AVFoundation

// ---------------------------------------------------------------------------
// Unified device item shown in the list
// ---------------------------------------------------------------------------
struct DeviceListItem: Identifiable {
    let id: String
    let name: String
    let subtitle: String
    let isDeckLink: Bool
}

struct DevicePickerView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var vm = DevicePickerViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            headerSection
            deviceListSection
            Button(action: vm.refresh) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
        .padding(24)
        .onChange(of: vm.selectedID) { id in
            DispatchQueue.main.async { applySelection(id: id) }
        }
        .onAppear {
            vm.refresh()
            // Restore selection from AppState
            if let dl = state.selectedDLDevice {
                vm.selectedID = dl.deviceID
            } else if let av = state.selectedDevice {
                vm.selectedID = av.uniqueID
            }
        }
    }

    // MARK: – Sub-views

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Select Video Capture Device")
                .font(.title2).bold()
            Text("All video capture devices recognised by macOS are listed below. "
                 + "AJA and Blackmagic devices appear automatically once their drivers "
                 + "are installed. DeckLink devices use native capture (no virtual camera needed).")
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var deviceListSection: some View {
        if vm.items.isEmpty {
            emptyDevicesView
        } else {
            List(vm.items, selection: $vm.selectedID) { item in
                deviceRow(item)
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(maxHeight: .infinity)
        }
    }

    private var emptyDevicesView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "camera.badge.exclamationmark")
                .font(.system(size: 40)).foregroundColor(.secondary)
            Text("No Capture Devices Found").font(.headline)
            Text("Connect your device and click Refresh.")
                .foregroundColor(.secondary).multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func deviceRow(_ item: DeviceListItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.isDeckLink ? "cable.connector" : "camera")
                .foregroundColor(.accentColor).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).fontWeight(.medium)
                Text(item.subtitle)
                    .font(.caption2).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
            if item.isDeckLink {
                Text("DeckLink")
                    .font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15))
                    .foregroundColor(.accentColor)
                    .cornerRadius(4)
            }
        }
        .padding(.vertical, 4)
        .tag(item.id)
    }

    // MARK: – Selection

    private func applySelection(id: String?) {
        guard let id else {
            state.selectedDevice   = nil
            state.selectedDLDevice = nil
            return
        }
        if let item = vm.items.first(where: { $0.id == id }) {
            if item.isDeckLink {
                state.selectedDevice   = nil
                state.selectedDLDevice = vm.dlDevices[id]
            } else {
                state.selectedDLDevice = nil
                state.selectedDevice   = vm.avDevices[id]
            }
        }
    }
}

// ---------------------------------------------------------------------------
// View model
// ---------------------------------------------------------------------------
@MainActor
final class DevicePickerViewModel: ObservableObject {
    @Published var items:      [DeviceListItem] = []
    @Published var selectedID: String?           = nil

    // Device registries for fast lookup on selection
    var avDevices: [String: AVCaptureDevice] = [:]
    var dlDevices: [String: DLDevice]        = [:]

    func refresh() {
        var result: [DeviceListItem] = []
        avDevices = [:]
        dlDevices = [:]

        // --- AVFoundation devices ---
        let deviceTypes: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            deviceTypes = [.external, .builtInWideAngleCamera, .continuityCamera]
        } else {
            deviceTypes = [.externalUnknown, .builtInWideAngleCamera]
        }
        let avSession = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video, position: .unspecified)
        for dev in avSession.devices {
            avDevices[dev.uniqueID] = dev
            result.append(DeviceListItem(
                id:         dev.uniqueID,
                name:       dev.localizedName,
                subtitle:   dev.uniqueID,
                isDeckLink: false))
        }

        // --- DeckLink devices (if runtime available) ---
        if DLDeviceEnumerator.isAvailable() {
            for dev in DLDeviceEnumerator.availableDevices() {
                dlDevices[dev.deviceID] = dev
                result.append(DeviceListItem(
                    id:         dev.deviceID,
                    name:       dev.name,
                    subtitle:   "Blackmagic DeckLink — native capture",
                    isDeckLink: true))
            }
        }

        items = result
    }
}
