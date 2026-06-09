import SwiftUI
import AppKit

struct AppPickerView: View {
    @EnvironmentObject var state: AppState
    @State private var installedApps: [AppInfo] = []
    @State private var searchText = ""

    struct AppInfo: Identifiable, Hashable {
        let id = UUID()
        let name: String
        let url: URL
        let icon: NSImage?
    }

    var filtered: [AppInfo] {
        if searchText.isEmpty { return installedApps }
        return installedApps.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Target Application")
                .font(.title2).bold()

            Text("Choose the application that should be launched or foregrounded, and receive the record / stop keyboard shortcut.")
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Current selection
            if let url = state.targetAppURL {
                HStack(spacing: 10) {
                    if let icon = NSWorkspace.shared.icon(forFile: url.path) as NSImage? {
                        Image(nsImage: icon).resizable().frame(width: 28, height: 28)
                    }
                    VStack(alignment: .leading) {
                        Text(state.targetAppName).fontWeight(.semibold)
                        Text(url.path).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button("Change…") { browseForApp() }
                }
                .padding(10)
                .background(Color.green.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.green.opacity(0.4)))
                .cornerRadius(8)
            }

            // Search field
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Search applications…", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)

            // App list
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(filtered) { app in
                        AppRow(app: app, isSelected: state.targetAppURL == app.url)
                            .onTapGesture { selectApp(app) }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)

            // Manual browse
            HStack {
                Spacer()
                Button("Browse for app…") { browseForApp() }
            }
        }
        .padding(24)
        .onAppear(perform: loadApps)
    }

    private func loadApps() {
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let appDirs = ["/Applications", "/Applications/Utilities",
                           NSHomeDirectory() + "/Applications"]
            var apps: [AppInfo] = []
            for dir in appDirs {
                guard let contents = try? fm.contentsOfDirectory(atPath: dir) else { continue }
                for name in contents where name.hasSuffix(".app") {
                    let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
                    let icon = NSWorkspace.shared.icon(forFile: url.path)
                    apps.append(AppInfo(name: String(name.dropLast(4)), url: url, icon: icon))
                }
            }
            let sorted = apps.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
            DispatchQueue.main.async { installedApps = sorted }
        }
    }

    private func selectApp(_ app: AppInfo) {
        state.targetAppURL = app.url
        state.targetAppName = app.name
    }

    private func browseForApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Select the application to control"
        if panel.runModal() == .OK, let url = panel.url {
            state.targetAppURL = url
            state.targetAppName = url.deletingPathExtension().lastPathComponent
        }
    }
}

private struct AppRow: View {
    let app: AppPickerView.AppInfo
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            if let icon = app.icon {
                Image(nsImage: icon).resizable().frame(width: 20, height: 20)
            } else {
                Image(systemName: "app").frame(width: 20, height: 20)
            }
            Text(app.name).lineLimit(1)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        .cornerRadius(6)
        .contentShape(Rectangle())
    }
}
