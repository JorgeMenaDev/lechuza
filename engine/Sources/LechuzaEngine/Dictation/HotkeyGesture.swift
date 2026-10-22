import Foundation

/// The dictation gestures as a pure state machine. Hold the hotkey to talk
/// and release to insert. Press it twice within `window` for hands-free, then
/// press once more to insert. Esc cancels. Capture starts on the first press,
/// so no word is lost while the machine tells a hold from a double-press.
///
/// Times are seconds on any monotonic clock. When `deadline` is set, the
/// driver sends `.timeout` once it passes.
struct HotkeyGesture: Equatable {
    enum Input: Equatable {
        case press, release
        case escape
        /// Any other key went down: while held, the hotkey was part of a shortcut.
        case otherKey
        /// The Flow bar was clicked: start or stop hands-free.
        case click
        case timeout
    }

    enum Action: Equatable {
        /// Start capturing.
        case start
        /// Stop, transcribe and insert.
        case commit
        /// Stop and throw the audio away.
        case cancel
    }

    enum State: Equatable {
        case idle
        /// Held since `at`: a hold if it lasts `window`, else the first of two presses.
        case pressed(at: TimeInterval)
        /// Released quickly; a second press before `until` means hands-free.
        case tapped(until: TimeInterval)
        case handsFree
        /// Stopped or interrupted while the key is still down.
        case awaitingRelease
    }

    /// How long a press must last to be a hold, and how soon a second press
    /// must follow a quick one.
    static let window: TimeInterval = 0.5

    private(set) var state = State.idle

    /// When to send `.timeout`.
    var deadline: TimeInterval? {
        if case .tapped(let until) = state { until } else { nil }
    }

    /// Whether a dictation is under way, so Esc belongs to Lechuza.
    var isDictating: Bool {
        switch state {
        case .pressed, .tapped, .handsFree: true
        case .idle, .awaitingRelease: false
        }
    }

    mutating func handle(_ input: Input, at time: TimeInterval) -> [Action] {
        switch (state, input) {
        case (.idle, .press), (.awaitingRelease, .press):
            state = .pressed(at: time)
            return [.start]
        case (.idle, .click):
            state = .handsFree
            return [.start]

        case (.pressed(let at), .release):
            if time - at >= Self.window {
                state = .idle
                return [.commit]
            }
            state = .tapped(until: time + Self.window)
            return []
        case (.pressed, .escape), (.pressed, .otherKey):
            state = .awaitingRelease
            return [.cancel]

        case (.tapped(let until), .press):
            if time < until {
                state = .handsFree
                return []
            }
            state = .pressed(at: time)
            return [.cancel, .start]
        case (.tapped(let until), .timeout):
            guard time >= until else { return [] }
            state = .idle
            return [.cancel]
        case (.tapped, .escape), (.tapped, .otherKey):
            state = .idle
            return [.cancel]

        case (.handsFree, .press):
            state = .awaitingRelease
            return [.commit]
        case (.handsFree, .click):
            state = .idle
            return [.commit]
        case (.handsFree, .escape):
            state = .idle
            return [.cancel]

        case (.awaitingRelease, .release):
            state = .idle
            return []

        default:
            return []
        }
    }
}
