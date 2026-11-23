import SwiftUI
import AVFoundation

// ---------------------------------------------------------------------------
// Unified device item shown in the list
// ---------------------------------------------------------------------------
struct DeviceListItem: Identifiable {
    enum Kind { case avFoundation, deckLink, ndi }

    let id: String
    let name: String
    let subtitle: String
    let kind: Kind
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
            } else if let ndi = state.selectedNDISource {
                vm.selectedID = ndi.sourceID
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
                 + "are installed. DeckLink devices and NDI sources on the network use native "
                 + "capture (no virtual camera needed).")
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
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40)).foregroundColor(.secondary)
            Text("No Capture Devices Found").font(.headline)
            Text(vm.isSearchingNDI ? "Looking for NDI sources…"
                                   : "Connect your device and click Refresh.")
                .foregroundColor(.secondary).multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func deviceRow(_ item: DeviceListItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon(for: item.kind))
                .foregroundColor(.accentColor).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).fontWeight(.medium)
                Text(item.subtitle)
                    .font(.caption2).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
            if let badge = badge(for: item.kind) {
                Text(badge)
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

    private func icon(for kind: DeviceListItem.Kind) -> String {
        switch kind {
        case .deckLink:     return "cable.connector"
        case .ndi:          return "network"
        case .avFoundation: return "camera"
        }
    }

    private func badge(for kind: DeviceListItem.Kind) -> String? {
        switch kind {
        case .deckLink:     return "DeckLink"
        case .ndi:          return "NDI"
        case .avFoundation: return nil
        }
    }

    // MARK: – Selection (called from tap gesture — outside view update)

    private func selectDevice(_ item: DeviceListItem) {
        print("[DevicePicker] selectDevice '\(item.name)' kind=\(item.kind) id=\(item.id)")
        state.selectedDevice    = nil
        state.selectedDLDevice  = nil
        state.selectedNDISource = nil
        switch item.kind {
        case .deckLink:
            let dev = vm.dlDevices[item.id]
            print("[DevicePicker] DLDevice lookup → \(dev?.name ?? "NIL — key not found")")
            state.selectedDLDevice = dev
        case .ndi:
            state.selectedNDISource = vm.ndiSources[item.id]
        case .avFoundation:
            state.selectedDevice = vm.avDevices[item.id]
        }
        print("[DevicePicker] AppState after: DL=\(state.selectedDLDevice?.name ?? "nil") NDI=\(state.selectedNDISource?.name ?? "nil") AV=\(state.selectedDevice?.localizedName ?? "nil")")
    }
}

// ---------------------------------------------------------------------------
// View model
// ---------------------------------------------------------------------------
@MainActor
final class DevicePickerViewModel: ObservableObject {
    @Published var items:      [DeviceListItem] = []
    @Published var selectedID: String?           = nil
    @Published var isSearchingNDI                = false

    var avDevices:  [String: AVCaptureDevice] = [:]
    var dlDevices:  [String: DLDevice]        = [:]
    var ndiSources: [String: NDISource]       = [:]

    /// Incremented on every refresh so a slow NDI search never appends to a newer list.
    private var refreshGeneration = 0

    func refresh() {
        var result: [DeviceListItem] = []
        avDevices  = [:]
        dlDevices  = [:]
        ndiSources = [:]
        refreshGeneration += 1

        // DeckLink devices first — these are the preferred (native) capture path.
        var dlNames: [String] = []
        if DLDeviceEnumerator.isAvailable() {
            let dlList = DLDeviceEnumerator.availableDevices()
            print("[DevicePicker] DeckLink devices: \(dlList.count) → \(dlList.map { $0.name })")
            for dev in dlList {
                dlDevices[dev.deviceID] = dev
                dlNames.append(dev.name)
                result.append(DeviceListItem(id: dev.deviceID, name: dev.name,
                                             subtitle: "Blackmagic DeckLink — native capture",
                                             kind: .deckLink))
            }
        } else {
            print("[DevicePicker] DeckLink runtime not available")
        }

        // AVFoundation devices — but skip any that duplicate a DeckLink device we
        // already listed (the CoreMediaIO/DAL plugin exposes a "Blackmagic <model>"
        // mirror of each DeckLink card). This guarantees a DeckLink device is only
        // ever offered via the native DeckLink API, never via AVFoundation.
        let deviceTypes: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            deviceTypes = [.external, .builtInWideAngleCamera, .continuityCamera]
        } else {
            deviceTypes = [.externalUnknown, .builtInWideAngleCamera]
        }
        let avSession = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes, mediaType: .video, position: .unspecified)
        for dev in avSession.devices {
            if Self.matchesDeckLink(avName: dev.localizedName, deckLinkNames: dlNames) {
                print("[DevicePicker] hiding AVFoundation duplicate of DeckLink device: \(dev.localizedName)")
                continue
            }
            avDevices[dev.uniqueID] = dev
            result.append(DeviceListItem(id: dev.uniqueID, name: dev.localizedName,
                                         subtitle: dev.uniqueID, kind: .avFoundation))
        }

        items = result
        refreshNDISources(generation: refreshGeneration)
    }

    /// NDI discovery waits for network announcements on the first call, so it
    /// runs off the main thread and its sources are appended when it returns.
    private func refreshNDISources(generation: Int) {
        guard NDISourceFinder.isAvailable() else {
            print("[DevicePicker] NDI runtime not available")
            return
        }
        isSearchingNDI = true
        Task.detached(priority: .userInitiated) {
            let sources = NDISourceFinder.availableSources(withTimeout: 2000)
            await MainActor.run {
                guard generation == self.refreshGeneration else { return }
                self.isSearchingNDI = false
                print("[DevicePicker] NDI sources: \(sources.count) → \(sources.map { $0.name })")
                for src in sources {
                    self.ndiSources[src.sourceID] = src
                    self.items.append(DeviceListItem(id: src.sourceID, name: src.name,
                                                     subtitle: "NDI — native network capture",
                                                     kind: .ndi))
                }
            }
        }
    }

    /// True when an AVFoundation device name refers to the same hardware as one of
    /// the DeckLink devices (the DAL plugin exposes "Blackmagic <model>" mirrors).
    private static func matchesDeckLink(avName: String, deckLinkNames: [String]) -> Bool {
        let av = avName.lowercased()
            .replacingOccurrences(of: "blackmagic", with: "")
            .trimmingCharacters(in: .whitespaces)
        return deckLinkNames.contains { dlRaw in
            let dl = dlRaw.lowercased()
                .replacingOccurrences(of: "blackmagic", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard !dl.isEmpty else { return false }
            return av == dl || av.contains(dl)
        }
    }
}
