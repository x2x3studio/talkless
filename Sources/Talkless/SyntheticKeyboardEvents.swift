import CoreGraphics

/// Marks only Talkless's own copy/paste events. Not an authorization boundary: the marker
/// prevents our event tap from treating clipboard automation as a physical dictation gesture.
enum SyntheticKeyboardEvents {
    private static let marker: Int64 = 0x54414C4B4C455353

    static func make(key: CGKeyCode, down: Bool, flags: CGEventFlags) -> CGEvent? {
        let source = CGEventSource(stateID: .privateState)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { return nil }
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        return event
    }

    static func isOurs(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == marker
    }
}
