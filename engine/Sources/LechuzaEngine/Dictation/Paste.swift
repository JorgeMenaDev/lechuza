import ApplicationServices

/// The synthetic ⌘V that types a dictation into the focused app, once the
/// text is on the clipboard.
enum Paste {
    /// How long the app gets to read the clipboard before it is restored.
    static let restoreDelay = Duration.milliseconds(500)

    /// ⌘ down, V down, V up, ⌘ up, marked as Lechuza's own. V is key code 9,
    /// its place on QWERTY, QWERTZ and AZERTY keyboards. Returns false
    /// without Accessibility, since macOS would drop the keystroke.
    static func pressCommandV() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let source = CGEventSource(stateID: .hidSystemState)
        let keys: [(code: CGKeyCode, down: Bool)] = [(55, true), (9, true), (9, false), (55, false)]
        for key in keys {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key.code, keyDown: key.down)
            event?.flags = key.code == 55 && !key.down ? [] : .maskCommand
            event?.setIntegerValueField(.eventSourceUserData, value: KeyTap.ownEvent)
            event?.post(tap: .cghidEventTap)
        }
        return true
    }
}
