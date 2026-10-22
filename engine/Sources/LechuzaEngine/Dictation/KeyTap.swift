import CoreGraphics
import Foundation
import Synchronization

/// Watches the keyboard in every app through a session event tap, which
/// macOS allows once Lechuza has Accessibility. `KeyFilter` turns each event
/// into a gesture input for `onInput`, with the time it happened, and says
/// which to swallow. The tap runs on its own thread, so a busy main actor
/// never delays a key.
final class KeyTap: @unchecked Sendable {
    /// Marks Lechuza's own keystrokes (the ⌘V that pastes), so they are not
    /// taken for the user's.
    static let ownEvent: Int64 = 0x4C43_485A

    /// Set while Esc belongs to Lechuza: a dictation is listening or waiting
    /// to paste.
    let escapeIsOurs = Mutex(false)
    private let onInput: @Sendable (HotkeyGesture.Input, TimeInterval) -> Void
    private var port: CFMachPort?
    private var runLoop: CFRunLoop?
    // Only touched on the tap's thread.
    private var filter: KeyFilter

    /// Nil when macOS refuses the tap: Accessibility isn't granted.
    init?(hotkey: Hotkey, onInput: @escaping @Sendable (HotkeyGesture.Input, TimeInterval) -> Void) {
        self.filter = KeyFilter(hotkey: hotkey) { CGEventSource.keyState(.combinedSessionState, key: CGKeyCode($0)) }
        self.onInput = onInput
        let events: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        guard
            let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: events.reduce(0) { $0 | 1 << $1.rawValue },
                callback: { _, type, event, info in
                    guard let info else { return Unmanaged.passUnretained(event) }
                    let tap = Unmanaged<KeyTap>.fromOpaque(info).takeUnretainedValue()
                    return tap.swallows(type, event) ? nil : Unmanaged.passUnretained(event)
                },
                userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return nil }
        self.port = port

        let started = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(runLoop, CFMachPortCreateRunLoopSource(nil, self.port, 0), .commonModes)
            started.signal()
            CFRunLoopRun()
        }
        thread.name = "app.lechuza.engine.keys"
        thread.start()
        started.wait()
    }

    /// Stops listening. Call before letting go of the tap.
    func stop() {
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
        if let runLoop { CFRunLoopStop(runLoop) }
        self.port = nil
    }

    /// Whether to drop `event` instead of passing it on.
    private func swallows(_ type: CGEventType, _ event: CGEvent) -> Bool {
        guard event.getIntegerValueField(.eventSourceUserData) != Self.ownEvent else { return false }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let key: KeyFilter.Event
        switch type {
        case .flagsChanged:
            key = .flagsChanged(keyCode: keyCode, flags: event.flags)
        case .keyDown:
            key = .keyDown(keyCode: keyCode, isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
        case .keyUp:
            key = .keyUp(keyCode: keyCode)
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS turns a slow tap off; turn it back on.
            FileHandle.standardError.write(Data("key tap turned off (\(type.rawValue)), turning it back on\n".utf8))
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            key = .tapDisabled
        default:
            return false
        }
        let (input, swallow) = filter.handle(key, escapeIsOurs: escapeIsOurs.withLock { $0 })
        if let input { onInput(input, ProcessInfo.processInfo.systemUptime) }
        return swallow
    }
}

/// The key tap's decisions, as a pure value the tests drive without a
/// keyboard: which events are the hotkey's presses and releases, Esc or
/// another key, and which to swallow. Esc is swallowed, with its key-up,
/// while it belongs to Lechuza. A hotkey pressed while another key is held
/// (→ then fn) is a shortcut: neither its press nor its release counts.
struct KeyFilter {
    enum Event: Equatable {
        case flagsChanged(keyCode: Int64, flags: CGEventFlags)
        case keyDown(keyCode: Int64, isRepeat: Bool)
        case keyUp(keyCode: Int64)
        /// macOS turned the tap off for a while, so events went missing.
        case tapDisabled
    }

    private static let escape: Int64 = 53
    /// 🌐, the fn key itself: macOS sends its keyDown and keyUp when fn/🌐 is tapped.
    private static let globe: Int64 = 179
    /// Every key code but the modifiers (54–63: ⌘ ⇧ ⇪ ⌥ ⌃ fn).
    private static let keys: [Int64] = Array(0..<54) + Array(64..<128)

    let hotkey: Hotkey
    /// Asks macOS whether a key is down now. The tap can't keep count itself:
    /// secure input hides key-ups, and it misses keys pressed while it was off.
    private let isKeyDown: (Int64) -> Bool
    private var down = false
    /// The hotkey went down while another key was held.
    private var chord = false
    private var swallowingEscape = false

    init(hotkey: Hotkey, isKeyDown: @escaping (Int64) -> Bool = { _ in false }) {
        self.hotkey = hotkey
        self.isKeyDown = isKeyDown
    }

    /// The gesture input `event` makes, if any, and whether to drop it.
    /// `escapeIsOurs`: a dictation is listening or waiting to paste.
    mutating func handle(_ event: Event, escapeIsOurs: Bool) -> (input: HotkeyGesture.Input?, swallow: Bool) {
        switch event {
        case .flagsChanged(let keyCode, let flags):
            guard let isDown = hotkey.isDown(keyCode: keyCode, flags: flags), isDown != down else { return (nil, false) }
            down = isDown
            if isDown { chord = Self.keys.contains(where: isKeyDown) }
            return (chord ? nil : isDown ? .press : .release, false)
        case .keyDown(Self.escape, _):
            guard escapeIsOurs else { return (nil, false) }
            swallowingEscape = true
            return (.escape, true)
        case .keyDown(Self.globe, _):
            return (nil, false)
        case .keyDown(_, let isRepeat):
            return (isRepeat ? nil : .otherKey, false)
        case .keyUp(Self.escape) where swallowingEscape:
            swallowingEscape = false
            return (nil, true)
        case .keyUp:
            return (nil, false)
        case .tapDisabled:
            // A release may be among the missing events: start over with the key up.
            self = KeyFilter(hotkey: hotkey, isKeyDown: isKeyDown)
            return (.interrupted, false)
        }
    }
}
