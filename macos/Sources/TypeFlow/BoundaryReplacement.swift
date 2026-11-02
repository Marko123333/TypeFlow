import CoreGraphics

/// Builds an entire replacement before emitting any event. The physical word
/// boundary is still pending, so neither its space nor any next-word character
/// is included in the deletion count.
struct BoundaryReplacement {
    let original: String
    let replacement: String
    let suffix: String
    let selectWord: Bool

    func makeEvents() -> [CGEvent]? {
        guard !original.isEmpty, original != replacement, !replacement.isEmpty,
              original.count + suffix.count <= 128,
              !selectWord || suffix.isEmpty,
              let source = CGEventSource(stateID: .privateState) else { return nil }
        source.userData = kLocalSwitcherEventMarker
        var events: [CGEvent] = []

        func appendKey(_ key: UInt16, flags: CGEventFlags = []) -> Bool {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return false }
            down.flags = flags
            up.flags = flags
            // Make control-key meaning explicit as well as its virtual code;
            // private event sources do not carry the physical keyboard state.
            let characters: [UniChar] = key == KC.backspace ? [0x7f] : [0xf702]
            characters.withUnsafeBufferPointer { buffer in
                down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
            events.append(contentsOf: [down, up])
            return true
        }

        if selectWord {
            guard appendKey(KC.left, flags: [.maskShift, .maskAlternate]) else { return nil }
        } else {
            for _ in 0..<(original.count + suffix.count) {
                guard appendKey(KC.backspace) else { return nil }
            }
        }
        let text = TextConverter.normalizedForInsert(replacement + suffix)
        let utf16 = Array(text.utf16)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return nil }
        down.flags = []
        up.flags = []
        utf16.withUnsafeBufferPointer { buffer in
            down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
        }
        events.append(contentsOf: [down, up])
        return events
    }
}
