import CoreGraphics
import Foundation
import Synchronization

/// Watches the keyboard in every app through a session event tap, which
/// macOS allows once Lechuza has Accessibility. Reports the hotkey's presses
/// and releases, Esc, and other keys to `onInput`, with the time they
/// happened. While `dictating` is set, Esc is swallowed so it cancels the
/// dictation without also reaching the app underneath. The tap runs on its
/// own thread, so a busy main actor never delays a key.
final class KeyTap: @unchecked Sendable {
    /// Marks Lechuza's own keystrokes (the ⌘V that pastes), so they are not
    /// taken for the user's.
    static let ownEvent: Int64 = 0x4C43_485A

    private static let escape: Int64 = 53

    let dictating = Mutex(false)
    private let hotkey: Hotkey
    private let onInput: @Sendable (HotkeyGesture.Input, TimeInterval) -> Void
    private var port: CFMachPort?
    private var runLoop: CFRunLoop?
    // Only touched on the tap's thread.
    private var down = false
    private var swallowingEscape = false

    /// Nil when macOS refuses the tap: Accessibility isn't granted.
    init?(hotkey: Hotkey, onInput: @escaping @Sendable (HotkeyGesture.Input, TimeInterval) -> Void) {
        self.hotkey = hotkey
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
        let now = ProcessInfo.processInfo.systemUptime
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard event.getIntegerValueField(.eventSourceUserData) != Self.ownEvent else { return false }
        switch type {
        case .flagsChanged:
            guard let isDown = hotkey.isDown(keyCode: keyCode, flags: event.flags), isDown != down else { return false }
            down = isDown
            onInput(isDown ? .press : .release, now)
            return false
        case .keyDown where keyCode == Self.escape:
            guard dictating.withLock({ $0 }) else { return false }
            swallowingEscape = true
            onInput(.escape, now)
            return true
        case .keyDown:
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { onInput(.otherKey, now) }
            return false
        case .keyUp where keyCode == Self.escape && swallowingEscape:
            swallowingEscape = false
            return true
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS turns a slow tap off; turn it back on.
            FileHandle.standardError.write(Data("key tap turned off (\(type.rawValue)), turning it back on\n".utf8))
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return false
        default:
            return false
        }
    }
}
