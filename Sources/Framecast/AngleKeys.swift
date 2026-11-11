import SwiftUI
import AppKit
import Carbon.HIToolbox

/// A key with optional modifiers, as Carbon hot keys take them (virtual key code, Carbon modifier mask).
struct KeyCombo: Codable, Hashable {
    var key: UInt32
    var mods: UInt32

    /// One key and no ⌘⌃⌥⇧: it stops typing elsewhere while switching keys are on.
    var isSingleKey: Bool { mods == 0 }

    var title: String {
        var s = ""
        if mods & UInt32(controlKey) != 0 { s += "⌃" }
        if mods & UInt32(optionKey) != 0 { s += "⌥" }
        if mods & UInt32(shiftKey) != 0 { s += "⇧" }
        if mods & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + Self.name(of: Int(key))
    }

    init(key: Int, mods: Int = 0) { self.key = UInt32(key); self.mods = UInt32(mods) }

    /// From a key press in Framecast (the recorder).
    init(event: NSEvent) {
        var m = 0
        let f = event.modifierFlags
        if f.contains(.control) { m |= controlKey }
        if f.contains(.option) { m |= optionKey }
        if f.contains(.shift) { m |= shiftKey }
        if f.contains(.command) { m |= cmdKey }
        self.init(key: Int(event.keyCode), mods: m)
    }

    static func name(of key: Int) -> String {
        if let n = names[key] { return n }
        if let f = fKeys.firstIndex(of: key) { return "F\(f + 1)" }
        return "Key \(key)"
    }

    private static let fKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
                                kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
    private static let names: [Int: String] = {
        var n: [Int: String] = [
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4", kVK_ANSI_5: "5",
            kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
            kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/",
            kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`", kVK_Space: "Space", kVK_Return: "Return", kVK_Tab: "Tab",
            kVK_Escape: "Esc", kVK_Delete: "Delete", kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→",
            kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "Home", kVK_End: "End", kVK_PageUp: "Page Up", kVK_PageDown: "Page Down",
            kVK_ANSI_Keypad0: "Keypad 0", kVK_ANSI_Keypad1: "Keypad 1", kVK_ANSI_Keypad2: "Keypad 2", kVK_ANSI_Keypad3: "Keypad 3",
            kVK_ANSI_Keypad4: "Keypad 4", kVK_ANSI_Keypad5: "Keypad 5", kVK_ANSI_Keypad6: "Keypad 6", kVK_ANSI_Keypad7: "Keypad 7",
            kVK_ANSI_Keypad8: "Keypad 8", kVK_ANSI_Keypad9: "Keypad 9", kVK_ANSI_KeypadEnter: "Keypad Enter",
            kVK_ANSI_KeypadPlus: "Keypad +", kVK_ANSI_KeypadMinus: "Keypad −", kVK_ANSI_KeypadMultiply: "Keypad ×",
            kVK_ANSI_KeypadDivide: "Keypad ÷", kVK_ANSI_KeypadDecimal: "Keypad .",
        ]
        let letters: [(Int, String)] = [(kVK_ANSI_A, "A"), (kVK_ANSI_B, "B"), (kVK_ANSI_C, "C"), (kVK_ANSI_D, "D"), (kVK_ANSI_E, "E"),
            (kVK_ANSI_F, "F"), (kVK_ANSI_G, "G"), (kVK_ANSI_H, "H"), (kVK_ANSI_I, "I"), (kVK_ANSI_J, "J"), (kVK_ANSI_K, "K"),
            (kVK_ANSI_L, "L"), (kVK_ANSI_M, "M"), (kVK_ANSI_N, "N"), (kVK_ANSI_O, "O"), (kVK_ANSI_P, "P"), (kVK_ANSI_Q, "Q"),
            (kVK_ANSI_R, "R"), (kVK_ANSI_S, "S"), (kVK_ANSI_T, "T"), (kVK_ANSI_U, "U"), (kVK_ANSI_V, "V"), (kVK_ANSI_W, "W"),
            (kVK_ANSI_X, "X"), (kVK_ANSI_Y, "Y"), (kVK_ANSI_Z, "Z")]
        for (k, v) in letters { n[k] = v }
        return n
    }()
}

/// What a switching key does.
enum AngleKeyAction: String, Codable, CaseIterable, Identifiable {
    case angle1, angle2, angle3, angle4, angle5, angle6, ownCamera, shuffle, next, previous
    var id: String { rawValue }
    var number: Int? { switch self { case .angle1: 1; case .angle2: 2; case .angle3: 3; case .angle4: 4; case .angle5: 5; case .angle6: 6; default: nil } }
    var title: String {
        if let n = number { return "Angle \(n)" }
        switch self {
        case .ownCamera: return "Your own camera"
        case .shuffle: return "Shuffle on or off"
        case .next: return "Next angle"
        case .previous: return "Previous angle"
        default: return rawValue
        }
    }
}

/// Ready-made sets of switching keys.
enum AngleKeyPreset: String, CaseIterable, Identifiable {
    case numbers, fKeys, keypad, option
    var id: String { rawValue }
    var title: String {
        switch self {
        case .numbers: "1–6, 0, S"
        case .fKeys: "F1–F6, F7, F8"
        case .keypad: "Keypad 1–6, 0, +"
        case .option: "⌥1–⌥6, ⌥0, ⌥S"
        }
    }
    var keys: [AngleKeyAction: KeyCombo] {
        let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6]
        var k: [AngleKeyAction: KeyCombo] = [:]
        let angles: [AngleKeyAction] = [.angle1, .angle2, .angle3, .angle4, .angle5, .angle6]
        switch self {
        case .numbers:
            for (a, d) in zip(angles, digits) { k[a] = KeyCombo(key: d) }
            k[.ownCamera] = KeyCombo(key: kVK_ANSI_0); k[.shuffle] = KeyCombo(key: kVK_ANSI_S)
            k[.next] = KeyCombo(key: kVK_ANSI_RightBracket); k[.previous] = KeyCombo(key: kVK_ANSI_LeftBracket)
        case .fKeys:
            for (a, f) in zip(angles, [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6]) { k[a] = KeyCombo(key: f) }
            k[.ownCamera] = KeyCombo(key: kVK_F7); k[.shuffle] = KeyCombo(key: kVK_F8)
            k[.next] = KeyCombo(key: kVK_F9); k[.previous] = KeyCombo(key: kVK_F10)
        case .keypad:
            let pad = [kVK_ANSI_Keypad1, kVK_ANSI_Keypad2, kVK_ANSI_Keypad3, kVK_ANSI_Keypad4, kVK_ANSI_Keypad5, kVK_ANSI_Keypad6]
            for (a, p) in zip(angles, pad) { k[a] = KeyCombo(key: p) }
            k[.ownCamera] = KeyCombo(key: kVK_ANSI_Keypad0); k[.shuffle] = KeyCombo(key: kVK_ANSI_KeypadPlus)
            k[.next] = KeyCombo(key: kVK_ANSI_KeypadMultiply); k[.previous] = KeyCombo(key: kVK_ANSI_KeypadDivide)
        case .option:
            for (a, d) in zip(angles, digits) { k[a] = KeyCombo(key: d, mods: optionKey) }
            k[.ownCamera] = KeyCombo(key: kVK_ANSI_0, mods: optionKey); k[.shuffle] = KeyCombo(key: kVK_ANSI_S, mods: optionKey)
            k[.next] = KeyCombo(key: kVK_ANSI_RightBracket, mods: optionKey); k[.previous] = KeyCombo(key: kVK_ANSI_LeftBracket, mods: optionKey)
        }
        return k
    }
}

/// Click, then press a key (or a key with ⌘⌃⌥⇧) to record it. Esc cancels, Delete clears.
struct KeyRecorderButton: View {
    let combo: KeyCombo?
    let recording: Bool
    var start: () -> Void
    var body: some View {
        Button(action: start) {
            Text(recording ? "Press a key…" : combo?.title ?? "None")
                .font(.fc(11.5, .semibold).monospaced())
                .foregroundStyle(recording ? Theme.accent : combo == nil ? Theme.text4 : Theme.text)
                .frame(minWidth: 86).padding(.horizontal, 8).frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(recording ? Theme.accentFill : Theme.field))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(recording ? Theme.accent : Theme.fieldBorder))
        }
        .buttonStyle(.plain)
    }
}

/// Catches the next key press anywhere in Framecast while a key is being recorded (a local event monitor, so no
/// permission is needed). Framecast's hot keys are taken off the system while recording, so the press reaches it.
/// Switching to another app or window cancels, so a later keystroke can't become the key by surprise.
final class KeyRecorder {
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    func begin(_ done: @escaping (KeyCombo?) -> Void, clear: @escaping () -> Void) {
        end()
        // Typing already going on in a field ends here, so a field focused after this is one the user chose.
        NSApp.keyWindow?.makeFirstResponder(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            // Typing into a field (Rename…, a search box) cancels recording and reaches the field.
            if e.window?.firstResponder is NSTextView { self?.end(); done(nil); return e }
            let plain = e.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
            let k = Int(e.keyCode)
            self?.end()
            if k == kVK_Escape && plain { done(nil) }
            else if (k == kVK_Delete || k == kVK_ForwardDelete) && plain { clear() }
            else { done(KeyCombo(event: e)) }
            return nil
        }
        for name in [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard self?.monitor != nil else { return }
                self?.end()
                done(nil)
            })
        }
    }
    func end() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
    }
}
