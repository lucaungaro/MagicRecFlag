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
            Button(action: { vm.refresh() }) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
        .padding(24)
        .onAppear {
            vm.refresh()
            // Restore visual selection from persisted AppState — no state write needed
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
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(vm.items) { item in
                        deviceRow(item)
                            .background(vm.selectedID == item.id
                                ? Color.accentColor.opacity(0.12)
                                : Color.clear)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                // Button action — runs outside SwiftUI view update cycle
                                vm.selectedID = item.id
                                selectDevice(item)
                            }
                        Divider()
                    }
                }
            }
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1))
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
            if vm.selectedID == item.id {
                Image(systemName: "checkmark")
                    .foregroundColor(.accentColor)
                    .font(.caption.bold())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: – Selection (called from tap gesture — outside view update)

    private func selectDevice(_ item: DeviceListItem) {
        print("[DevicePicker] selectDevice '\(item.name)' isDeckLink=\(item.isDeckLink) id=\(item.id)")
        if item.isDeckLink {
            let dev = vm.dlDevices[item.id]
            print("[DevicePicker] DLDevice lookup → \(dev?.name ?? "NIL — key not found")")
            state.selectedDevice   = nil
            state.selectedDLDevice = dev
        } else {
            state.selectedDLDevice = nil
            state.selectedDevice   = vm.avDevices[item.id]
        }
        print("[DevicePicker] AppState after: DL=\(state.selectedDLDevice?.name ?? "nil") AV=\(state.selectedDevice?.localizedName ?? "nil")")
    }
}

// ---------------------------------------------------------------------------
// View model
// ---------------------------------------------------------------------------
@MainActor
final class DevicePickerViewModel: ObservableObject {
    @Published var items:      [DeviceListItem] = []
    @Published var selectedID: String?           = nil

    var avDevices: [String: AVCaptureDevice] = [:]
    var dlDevices: [String: DLDevice]        = [:]

    func refresh() {
        var result: [DeviceListItem] = []
        avDevices = [:]
        dlDevices = [:]

        // AVFoundation devices
        let deviceTypes: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            deviceTypes = [.external, .builtInWideAngleCamera, .continuityCamera]
        } else {
            deviceTypes = [.externalUnknown, .builtInWideAngleCamera]
        }
        let avSession = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes, mediaType: .video, position: .unspecified)
        for dev in avSession.devices {
            avDevices[dev.uniqueID] = dev
            result.append(DeviceListItem(id: dev.uniqueID, name: dev.localizedName,
                                         subtitle: dev.uniqueID, isDeckLink: false))
        }

        // DeckLink devices
        if DLDeviceEnumerator.isAvailable() {
            for dev in DLDeviceEnumerator.availableDevices() {
                dlDevices[dev.deviceID] = dev
                result.append(DeviceListItem(id: dev.deviceID, name: dev.name,
                                             subtitle: "Blackmagic DeckLink — native capture",
                                             isDeckLink: true))
            }
        }

        items = result
    }
}
