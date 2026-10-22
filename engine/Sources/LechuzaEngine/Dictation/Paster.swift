import AppKit

/// Types a dictation into the app that had focus when it stopped: puts the
/// words on the clipboard, presses ⌘V, and puts the clipboard back once
/// that app has read them. It touches the clipboard only when it can press
/// the keys and the app is still in front.
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
    /// How long an app gets to read the words before the clipboard comes
    /// back anyway: one busy enough to take this long is rare.
    private let readTimeout: Duration
    /// The clipboard as it was before the latest paste, until it is put back.
    private var swapped: ClipboardSnapshot?

    init(system: System = .mac, readTimeout: Duration = .seconds(5)) {
        self.system = system
        self.readTimeout = readTimeout
    }

    /// The app in front now: where a dictation that stops now goes.
    func target() -> pid_t? {
        system.frontmostApp()
    }

    /// Pastes `text` into `target`. Call `restoreClipboard()` before the
    /// next paste.
    func paste(_ text: String, into target: pid_t?) -> Outcome {
        guard system.trusted() else { return .noAccessibility }
        guard system.frontmostApp() == target else { return .appChanged }
        let clipboard = ClipboardSnapshot(promising: text, on: system.pasteboard)
        guard system.pressCommandV() else {
            clipboard.restore()
            return .failed
        }
        swapped = clipboard
        return .pasted
    }

    /// Puts back what the clipboard held before the latest paste, once the
    /// app has read the words, or after `readTimeout`.
    func restoreClipboard() async {
        guard let clipboard = swapped else { return }
        swapped = nil
        if await clipboard.waitForRead(timeout: readTimeout) {
            // One paste can read the clipboard more than once.
            try? await Task.sleep(for: .milliseconds(200))
        }
        clipboard.restore()
    }
}
