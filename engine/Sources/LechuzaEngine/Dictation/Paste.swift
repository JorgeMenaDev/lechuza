import Carbon
import CoreGraphics

/// The synthetic ⌘V that types a dictation into the focused app, once the
/// text is on the clipboard.
enum Paste {
    /// ⌘ down, V down, V up, ⌘ up, marked as Lechuza's own, with V wherever
    /// the active keyboard layout puts it. Returns false when macOS won't
    /// make the events.
    static func pressCommandV() -> Bool {
        let v = TISCopyCurrentKeyboardLayoutInputSource().map { vKey(in: $0.takeRetainedValue()) } ?? 9
        let source = CGEventSource(stateID: .hidSystemState)
        let keys: [(code: CGKeyCode, down: Bool)] = [(55, true), (v, true), (v, false), (55, false)]
        let events = keys.compactMap { key in
            let event = CGEvent(keyboardEventSource: source, virtualKey: key.code, keyDown: key.down)
            event?.flags = key.code == 55 && !key.down ? [] : .maskCommand
            event?.setIntegerValueField(.eventSourceUserData, value: KeyTap.ownEvent)
            return event
        }
        guard events.count == keys.count else { return false }
        for event in events { event.post(tap: .cghidEventTap) }
        return true
    }

    /// The key that types "v" with ⌘ held in `layout`: 9 on QWERTY, 47 on
    /// Dvorak, 9 again on "Dvorak – QWERTY ⌘".
    static func vKey(in layout: TISInputSource) -> CGKeyCode {
        guard let property = TISGetInputSourceProperty(layout, kTISPropertyUnicodeKeyLayoutData) else { return 9 }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        return data.withUnsafeBytes { bytes in
            guard let keyboard = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return 9 }
            return vKey { code in
                var deadKeys: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    keyboard, code, UInt16(kUCKeyActionDown), UInt32((cmdKey >> 8) & 0xFF), UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeys, characters.count, &length, &characters)
                return status == noErr ? String(utf16CodeUnits: characters, count: length) : nil
            }
        }
    }

    /// The first key that `character` says types "v", or 9 (V on QWERTY) when
    /// none does.
    static func vKey(_ character: (CGKeyCode) -> String?) -> CGKeyCode {
        (0..<128).map(CGKeyCode.init).first { character($0) == "v" } ?? 9
    }
}
