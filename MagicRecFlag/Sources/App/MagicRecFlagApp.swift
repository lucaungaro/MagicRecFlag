import SwiftUI

@main
struct MagicRecFlagApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("Magic Rec Flag – Setup") {
            SetupContainerView()
                .environmentObject(AppState.shared)
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
