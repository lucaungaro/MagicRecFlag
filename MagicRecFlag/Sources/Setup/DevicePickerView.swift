import SwiftUI
import AVFoundation

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
            state.selectedDevice = vm.devices.first { $0.uniqueID == id }
        }
        .onAppear {
            vm.refresh()
            if let current = state.selectedDevice {
                vm.selectedID = current.uniqueID
            }
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Select Video Capture Device")
                .font(.title2).bold()
            Text("All video capture devices recognised by macOS are listed below. AJA and Blackmagic devices appear here automatically once their drivers are installed.")
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var deviceListSection: some View {
        if vm.devices.isEmpty {
            emptyDevicesView
        } else {
            List(vm.devices, id: \.uniqueID, selection: $vm.selectedID) { device in
                deviceRow(device)
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(maxHeight: .infinity)
        }
    }

    private var emptyDevicesView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "camera.badge.exclamationmark")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("No Capture Devices Found")
                .font(.headline)
            Text("Make sure your AJA or Blackmagic device is connected and its driver is installed.")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func deviceRow(_ device: AVCaptureDevice) -> some View {
        HStack(spacing: 12) {
            Image(systemName: deviceIcon(device))
                .foregroundColor(.accentColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.localizedName)
                    .fontWeight(.medium)
                Text(device.uniqueID)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .tag(device.uniqueID)
    }

    private func deviceIcon(_ device: AVCaptureDevice) -> String {
        let name = device.localizedName.lowercased()
        if name.contains("aja") || name.contains("blackmagic") || name.contains("magewell") {
            return "camera.on.rectangle"
        }
        return "camera"
    }
}

@MainActor
final class DevicePickerViewModel: ObservableObject {
    @Published var devices: [AVCaptureDevice] = []
    @Published var selectedID: String? = nil

    func refresh() {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .externalUnknown,
                .builtInWideAngleCamera
            ],
            mediaType: .video,
            position: .unspecified
        )
        devices = session.devices
    }
}
