import AppKit

/// Types a dictation into the app that had focus when it stopped: puts the
/// words on the clipboard, presses ⌘V, and puts the clipboard back after a
/// hold long enough for a busy app to read them. Nothing on the Mac says
/// which app read the clipboard (a clipboard manager reads every change at
/// once), so the hold is a fixed time. It touches the clipboard only when
/// it can press the keys and the app is still in front.
@MainActor
final class Paster {
    enum Outcome: Equatable {
        case pasted
        /// Lechuza lacks Accessibility, so macOS would drop the ⌘V.
        case noAccessibility
        /// Another app came to the front since the dictation stopped.
        case appChanged
        /// macOS wouldn't make the keystroke.
        case failed
    }

    /// The parts of the Mac that pasting uses; tests swap in fakes.
    struct System {
        var trusted: @MainActor () -> Bool
        var frontmostApp: @MainActor () -> pid_t?
        var pressCommandV: @MainActor () -> Bool
        var pasteboard: NSPasteboard

        static var mac: System {
            System(
                trusted: { AXIsProcessTrusted() },
                frontmostApp: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
                pressCommandV: Paste.pressCommandV,
                pasteboard: .general)
        }
    }

    private let system: System
    /// How long the words stay on the clipboard: an app busy enough to take
    /// longer to handle ⌘V is rare.
    private let holdFor: Duration
    /// The clipboard as it was before the paste in its hold.
    private var held: ClipboardSnapshot?

    init(system: System = .mac, holdFor: Duration = .seconds(2)) {
        self.system = system
        self.holdFor = holdFor
    }

    /// The app in front now: where a dictation that stops now goes.
    func target() -> pid_t? {
        system.frontmostApp()
    }

    /// Pastes `text` into `target`. Await `giveBack()` before the next paste:
    /// the app may not have read these words yet.
    func paste(_ text: String, into target: pid_t?) -> Outcome {
        assert(held == nil, "await giveBack() before the next paste, or a slow app reads the next dictation")
        guard system.trusted() else { return .noAccessibility }
        guard system.frontmostApp() == target else { return .appChanged }
        let clipboard = ClipboardSnapshot(replacingWith: text, on: system.pasteboard)
        guard system.pressCommandV() else {
            clipboard.restore()
            return .failed
        }
        held = clipboard
        return .pasted
    }

    /// Waits out the hold, then puts the user's clipboard back.
    func giveBack() async {
        guard let held else { return }
        try? await Task.sleep(for: holdFor)
        held.restore()
        self.held = nil
    }
}
