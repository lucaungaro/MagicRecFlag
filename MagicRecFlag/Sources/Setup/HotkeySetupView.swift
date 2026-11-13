import SwiftUI
import AppKit

struct HotkeySetupView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Keyboard Shortcuts")
                .font(.title2).bold()

            Text("Set the shortcuts that Magic Rec Flag will send to your target application. Add several to send them one after the other. Start and stop can be identical if your app uses one key to toggle recording.")
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                VStack(spacing: 16) {
                    HotkeySequenceRow(label: "Start Recording", hotkeys: $state.recordHotkeys)
                    Divider()
                    HotkeySequenceRow(label: "Stop Recording", hotkeys: $state.stopHotkeys)

                    if state.hasValidShortcuts &&
                       state.recordHotkeys.sequenceDisplay == state.stopHotkeys.sequenceDisplay {
                        Label("Same shortcut for start and stop — the app will toggle.", systemImage: "info.circle")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(8)
            } label: {
                Label("Shortcuts sent to target app", systemImage: "keyboard")
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Click a recorder field, then press your desired shortcut combination.")
                        .font(.caption).foregroundColor(.secondary)
                    Text("Examples: ⌘R, ⌃⌥Space, F9")
                        .font(.caption).foregroundColor(.secondary)
                }
                .padding(8)
            } label: {
                Label("How to use", systemImage: "questionmark.circle")
            }

            Spacer()
        }
        .padding(24)
    }
}

// MARK: – Shortcut sequence row

/// One or more shortcuts, sent in order (top to bottom).
struct HotkeySequenceRow: View {
    let label: String
    @Binding var hotkeys: [HotkeyDefinition]

    private let maxCount = 5

    var body: some View {
        HStack(alignment: .top) {
            Text(label).frame(width: 160, alignment: .leading)
                .padding(.top, 6)
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(hotkeys.indices, id: \.self) { i in
                    HStack(spacing: 8) {
                        Text(i == 0 ? "" : "then")
                            .font(.caption).foregroundColor(.secondary)
                            .frame(width: 30, alignment: .trailing)
                        HotkeyRecorderField(hotkey: binding(at: i))
                        removeButton(at: i)
                    }
                }
                if hotkeys.count < maxCount, hotkeys.last?.isValid == true {
                    Button(action: { hotkeys.append(HotkeyDefinition()) }) {
                        Label("Add shortcut", systemImage: "plus")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .padding(.trailing, 26)
                }
            }
        }
    }

    // Bound by index; guards against the row being removed while SwiftUI
    // still renders the old index.
    private func binding(at i: Int) -> Binding<HotkeyDefinition> {
        Binding(
            get: { i < hotkeys.count ? hotkeys[i] : HotkeyDefinition() },
            set: { if i < hotkeys.count { hotkeys[i] = $0 } })
    }

    /// Clears the only shortcut; removes any other one from the sequence.
    @ViewBuilder
    private func removeButton(at i: Int) -> some View {
        let visible = hotkeys.count > 1 || (i < hotkeys.count && hotkeys[i].isValid)
        Button(action: {
            guard i < hotkeys.count else { return }
            if hotkeys.count > 1 { hotkeys.remove(at: i) } else { hotkeys[0] = HotkeyDefinition() }
        }) {
            Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .opacity(visible ? 1 : 0)
        .disabled(!visible)
    }
}

// MARK: – NSView-based key recorder (captures raw key events)

struct HotkeyRecorderField: NSViewRepresentable {
    @Binding var hotkey: HotkeyDefinition

    func makeNSView(context: Context) -> HotkeyRecorderNSView {
        let view = HotkeyRecorderNSView()
        view.onChange = { definition in
            DispatchQueue.main.async { hotkey = definition }
        }
        return view
    }

    func updateNSView(_ nsView: HotkeyRecorderNSView, context: Context) {
        nsView.currentDefinition = hotkey
    }
}

final class HotkeyRecorderNSView: NSView {
    var onChange: ((HotkeyDefinition) -> Void)?
    var currentDefinition: HotkeyDefinition = HotkeyDefinition() {
        didSet { needsDisplay = true }
    }
    private var isRecording = false

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let bg: NSColor = isRecording ? .selectedControlColor : .controlBackgroundColor
        bg.setFill()
        let path = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        path.fill()

        NSColor.separatorColor.setStroke()
        path.stroke()

        let text: String
        let color: NSColor
        if isRecording {
            text = "Press shortcut…"
            color = .tertiaryLabelColor
        } else if currentDefinition.isValid {
            text = currentDefinition.displayString
            color = .labelColor
        } else {
            text = "Click to record"
            color = .placeholderTextColor
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: color
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        str.draw(at: NSPoint(x: (bounds.width - size.width)/2, y: (bounds.height - size.height)/2))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return }

        // Escape cancels
        if event.keyCode == 53 {
            isRecording = false
            needsDisplay = true
            return
        }

        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let displayString = modifierString(modifiers) + keyString(event)

        let definition = HotkeyDefinition(
            keyCode: event.keyCode,
            modifiers: modifiers,
            displayString: displayString
        )
        currentDefinition = definition
        onChange?(definition)
        isRecording = false
        needsDisplay = true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        needsDisplay = true
        return super.resignFirstResponder()
    }

    // MARK: – Helpers

    private func modifierString(_ flags: NSEvent.ModifierFlags) -> String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option)  { s += "⌥" }
        if flags.contains(.shift)   { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s
    }

    private func keyString(_ event: NSEvent) -> String {
        let specialKeys: [UInt16: String] = [
            36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "Esc",
            96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8",
            101: "F9", 103: "F11", 109: "F10", 111: "F12",
            115: "Home", 116: "⇞", 117: "Del", 119: "End",
            121: "⇟", 122: "F1", 120: "F2", 123: "←", 124: "→",
            125: "↓", 126: "↑"
        ]
        if let special = specialKeys[event.keyCode] { return special }
        return event.charactersIgnoringModifiers?.uppercased() ?? "?"
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 160, height: 30)
    }
}
