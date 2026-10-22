import CoreGraphics
import XCTest

@testable import LechuzaEngine

/// What the key tap makes of keyboard events, with right Option as the hotkey.
final class KeyFilterTests: XCTestCase {
    private var filter = KeyFilter(hotkey: .rightOption)
    private let optionDown = KeyFilter.Event.flagsChanged(
        keyCode: 61, flags: CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40))
    private let optionUp = KeyFilter.Event.flagsChanged(keyCode: 61, flags: [])
    private let escDown = KeyFilter.Event.keyDown(keyCode: 53, isRepeat: false)
    private let escUp = KeyFilter.Event.keyUp(keyCode: 53)

    private func inputs(_ events: [KeyFilter.Event], escapeIsOurs: Bool = false) -> [HotkeyGesture.Input?] {
        events.map { filter.handle($0, escapeIsOurs: escapeIsOurs).input }
    }

    func testTheHotkeyPressesAndReleasesOnce() {
        XCTAssertEqual(inputs([optionDown, optionDown, optionUp]), [.press, nil, .release])
    }

    func testATurnedOffTapStartsOverWithTheKeyUp() {
        // The release went missing while macOS had the tap off.
        XCTAssertEqual(inputs([optionDown, .tapDisabled]), [.press, .interrupted])
        XCTAssertEqual(inputs([optionDown]), [.press], "the next press counts")
    }

    func testEscBelongsToLechuzaOnlyWhileItIsDictatingOrTranscribing() {
        XCTAssertEqual(filter.handle(escDown, escapeIsOurs: false).swallow, false)
        XCTAssertEqual(filter.handle(escUp, escapeIsOurs: false).swallow, false)

        let down = filter.handle(escDown, escapeIsOurs: true)
        XCTAssertEqual(down.input, .escape)
        XCTAssertTrue(down.swallow)
        XCTAssertTrue(filter.handle(escUp, escapeIsOurs: false).swallow, "its key-up goes with it")
        XCTAssertFalse(filter.handle(escUp, escapeIsOurs: false).swallow)
    }

    func testOtherKeysPassThroughAndMarkAShortcut() {
        let arrow = filter.handle(.keyDown(keyCode: 124, isRepeat: false), escapeIsOurs: true)
        XCTAssertEqual(arrow.input, .otherKey)
        XCTAssertFalse(arrow.swallow)
        XCTAssertNil(filter.handle(.keyDown(keyCode: 124, isRepeat: true), escapeIsOurs: true).input)
    }

    /// → held, then the hotkey: a shortcut, so neither its press nor its
    /// release reaches the gesture (in hands-free, that release would stop it).
    func testAHotkeyPressedWhileAnotherKeyIsHeldIsAShortcut() {
        var arrowHeld = true
        filter = KeyFilter(hotkey: .rightOption) { $0 == 124 && arrowHeld }
        let arrowDown = KeyFilter.Event.keyDown(keyCode: 124, isRepeat: false)
        let arrowRepeat = KeyFilter.Event.keyDown(keyCode: 124, isRepeat: true)
        XCTAssertEqual(inputs([arrowDown, optionDown, arrowRepeat, optionUp]), [.otherKey, nil, nil, nil])
        arrowHeld = false
        XCTAssertEqual(inputs([.keyUp(keyCode: 124), optionDown]), [nil, .press], "once → is up, the hotkey counts")
    }

    /// The tap never saw → go down (it was off, or → was held before
    /// Lechuza started): macOS still knows it is held.
    func testAKeyHeldWhileTheTapWasOffStillMakesAShortcut() {
        filter = KeyFilter(hotkey: .rightOption) { $0 == 124 }
        XCTAssertEqual(inputs([.tapDisabled, optionDown, optionUp]), [.interrupted, nil, nil])
    }

    /// The hotkey itself, and a modifier held with it (⇧ here), don't make
    /// it a shortcut.
    func testAModifierHeldWithTheHotkeyStillCounts() {
        filter = KeyFilter(hotkey: .rightOption) { $0 == 61 || $0 == 56 }
        XCTAssertEqual(inputs([optionDown, optionUp]), [.press, .release])
    }
}
