import Foundation

/// Physical key code plus Carbon modifier bits. A nil key explicitly disables the shortcut.
/// Kept independent of AppKit so preferences can be validated without installing a hotkey.
struct TranslationShortcut: Codable, Equatable, Sendable {
    struct Modifiers: OptionSet, Codable, Sendable {
        let rawValue: UInt32
        static let command = Self(rawValue: 256)
        static let shift = Self(rawValue: 512)
        static let option = Self(rawValue: 2048)
        static let control = Self(rawValue: 4096)
        static let all: Self = [.command, .shift, .option, .control]
    }

    let keyCode: UInt16?
    let modifiers: Modifiers

    static let `default` = Self(keyCode: 17, modifiers: [.control, .option])
    static let disabled = Self(keyCode: nil, modifiers: [])

    var title: String {
        guard let keyCode else { return "Disabled" }
        return (modifiers.contains(.control) ? "⌃" : "")
            + (modifiers.contains(.option) ? "⌥" : "")
            + (modifiers.contains(.shift) ? "⇧" : "")
            + (modifiers.contains(.command) ? "⌘" : "")
            + (Self.keyNames[keyCode] ?? "Key \(keyCode)")
    }

    var validationError: String? {
        guard let keyCode else {
            return modifiers.isEmpty ? nil : "A disabled shortcut cannot have modifiers."
        }
        guard Self.keyNames[keyCode] != nil else {
            return "Use a letter, number, punctuation, arrow, Space, Tab, or Return key."
        }
        guard modifiers.subtracting(.all).isEmpty,
              !modifiers.intersection([.command, .control, .option]).isEmpty else {
            return "Include Command, Control, or Option with a non-modifier key."
        }
        // These common macOS shortcuts may never reach local capture or Carbon registration.
        let reserved = (keyCode == 49 && (modifiers == .command || modifiers == [.command, .option]
                                        || modifiers == .control || modifiers == [.control, .option]))
            || (keyCode == 48 && modifiers.contains(.command))
            || ([18, 19, 20, 21, 23].contains(keyCode) && modifiers == [.command, .shift])
            || (keyCode == 2 && modifiers == [.command, .option])
            || (keyCode == 12 && modifiers == [.command, .control])
            || ([123, 124, 125, 126].contains(keyCode) && modifiers == .control)
        return reserved ? "That combination is reserved by macOS. Record a different shortcut." : nil
    }

    private static let keyNames: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2",
        20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8",
        29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Return",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N",
        46: "M", 47: ".", 48: "Tab", 49: "Space", 50: "`", 123: "←", 124: "→", 125: "↓", 126: "↑"
    ]
}
