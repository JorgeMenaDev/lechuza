import XCTest

@testable import LechuzaEngine

/// Hold to talk, double-press for hands-free, a press to stop it, Esc to
/// cancel. Times are seconds.
final class HotkeyGestureTests: XCTestCase {
    private var gesture = HotkeyGesture()

    private func run(_ steps: [(HotkeyGesture.Input, TimeInterval)]) -> [[HotkeyGesture.Action]] {
        steps.map { gesture.handle($0.0, at: $0.1) }
    }

    func testHoldingDictatesUntilRelease() {
        XCTAssertEqual(run([(.press, 0), (.release, 1.2)]), [[.start], [.commit]])
        XCTAssertEqual(gesture.state, .idle)
    }

    func testAQuickPressAloneIsDismissedWhenTheWindowCloses() {
        XCTAssertEqual(run([(.press, 0), (.release, 0.2)]), [[.start], []])
        XCTAssertEqual(gesture.deadline, 0.7)
        XCTAssertEqual(gesture.handle(.timeout, at: 0.7), [.cancel])
        XCTAssertEqual(gesture.state, .idle)
        XCTAssertNil(gesture.deadline)
    }

    func testDoublePressDictatesHandsFreeUntilTheNextPress() {
        XCTAssertEqual(run([(.press, 0), (.release, 0.15), (.press, 0.4), (.release, 0.5)]), [[.start], [], [], []])
        XCTAssertEqual(gesture.state, .handsFree)
        XCTAssertEqual(gesture.handle(.timeout, at: 0.65), [], "a stale timer changes nothing")
        XCTAssertEqual(run([(.press, 6), (.release, 6.1)]), [[], [.commit]], "the stop press counts once it comes up")
        XCTAssertEqual(gesture.state, .idle)
    }

    func testEscapeCancelsAnyDictation() {
        XCTAssertEqual(run([(.press, 0), (.escape, 0.8)]), [[.start], [.cancel]])
        XCTAssertEqual(gesture.state, .awaitingRelease)
        XCTAssertEqual(run([(.release, 0.9)]), [[]])

        XCTAssertEqual(run([(.press, 2), (.release, 2.1), (.escape, 2.3)]), [[.start], [], [.cancel]])
        XCTAssertEqual(gesture.state, .idle)

        XCTAssertEqual(run([(.press, 4), (.release, 4.1), (.press, 4.3), (.release, 4.4)]), [[.start], [], [], []])
        XCTAssertEqual(run([(.escape, 9)]), [[.cancel]])
        XCTAssertEqual(gesture.state, .idle)
    }

    func testEscapeBelongsToLechuzaOnlyWhileDictating() {
        XCTAssertFalse(gesture.isDictating)
        XCTAssertEqual(gesture.handle(.escape, at: 0), [])
        _ = gesture.handle(.press, at: 1)
        XCTAssertTrue(gesture.isDictating)
        _ = gesture.handle(.release, at: 1.1)
        XCTAssertTrue(gesture.isDictating, "waiting for a second press")
        _ = gesture.handle(.press, at: 1.3)
        XCTAssertTrue(gesture.isDictating, "the second press")
        _ = gesture.handle(.release, at: 1.4)
        XCTAssertTrue(gesture.isDictating, "hands-free")
        _ = gesture.handle(.press, at: 5)
        XCTAssertTrue(gesture.isDictating, "a stop press, until it comes up alone")
        _ = gesture.handle(.release, at: 5.1)
        XCTAssertFalse(gesture.isDictating, "stopped")
    }

    func testAnotherKeyWhileHoldingIsAShortcutNotDictation() {
        // fn + ← is Home: the press was part of a shortcut.
        XCTAssertEqual(run([(.press, 0), (.otherKey, 0.3), (.release, 0.4)]), [[.start], [.cancel], []])
        XCTAssertEqual(gesture.state, .idle)
        XCTAssertEqual(run([(.press, 1), (.release, 1.1), (.otherKey, 1.2)]), [[.start], [], [.cancel]])
        XCTAssertEqual(gesture.state, .idle)
    }

    func testTypingDuringHandsFreeKeepsDictating() {
        _ = run([(.press, 0), (.release, 0.1), (.press, 0.3), (.release, 0.4)])
        XCTAssertEqual(gesture.handle(.otherKey, at: 1), [])
        XCTAssertEqual(gesture.state, .handsFree)
    }

    func testAShortcutDuringHandsFreeKeepsDictating() {
        // fn + → moves the cursor; it isn't the stop press.
        _ = run([(.press, 0), (.release, 0.1), (.press, 0.3), (.release, 0.4)])
        XCTAssertEqual(run([(.press, 3), (.otherKey, 3.1), (.release, 3.2)]), [[], [], []])
        XCTAssertEqual(gesture.state, .handsFree)
        XCTAssertEqual(run([(.press, 6), (.release, 6.1)]), [[], [.commit]])
    }

    func testATapThenAShortcutIsNotHandsFree() {
        // A quick fn, then fn + → straight after: the second press was a shortcut.
        XCTAssertEqual(
            run([(.press, 0), (.release, 0.1), (.press, 0.3), (.otherKey, 0.35), (.release, 0.4)]),
            [[.start], [], [], [.cancel], []])
        XCTAssertEqual(gesture.state, .idle)
    }

    func testLostKeysOrMicrophoneCancelAnyDictation() {
        XCTAssertEqual(run([(.press, 0), (.interrupted, 0.3)]), [[.start], [.cancel]])
        XCTAssertEqual(gesture.state, .idle, "the next press starts afresh, even if the release was lost")
        _ = run([(.press, 1), (.release, 1.1), (.press, 1.3), (.release, 1.4)])
        XCTAssertEqual(run([(.interrupted, 5)]), [[.cancel]])
        XCTAssertEqual(gesture.state, .idle)
        XCTAssertEqual(run([(.interrupted, 6)]), [[]], "nothing to cancel")
    }

    func testAQuickPressAfterAHoldStartsANewDictation() {
        XCTAssertEqual(run([(.press, 0), (.release, 1), (.press, 1.1)]), [[.start], [.commit], [.start]])
        XCTAssertEqual(gesture.state, .pressed(at: 1.1))
    }

    func testASecondPressAfterTheWindowStartsAfresh() {
        // The timer hasn't fired yet, but the window has closed.
        XCTAssertEqual(run([(.press, 0), (.release, 0.1), (.press, 0.7)]), [[.start], [], [.cancel, .start]])
        XCTAssertEqual(gesture.state, .pressed(at: 0.7))
    }

    func testClickingTheFlowBarStartsAndStopsHandsFree() {
        XCTAssertEqual(run([(.click, 0)]), [[.start]])
        XCTAssertEqual(gesture.state, .handsFree)
        XCTAssertEqual(run([(.click, 3)]), [[.commit]])
        XCTAssertEqual(gesture.state, .idle)
    }

    func testClicksDuringAHoldAreIgnored() {
        XCTAssertEqual(run([(.press, 0), (.click, 0.2), (.release, 1)]), [[.start], [], [.commit]])
    }

    func testAPressAfterALostReleaseStartsDictating() {
        _ = run([(.press, 0), (.otherKey, 0.2)])
        XCTAssertEqual(gesture.state, .awaitingRelease)
        XCTAssertEqual(gesture.handle(.press, at: 5), [.start])
        XCTAssertEqual(gesture.state, .pressed(at: 5))
    }
}
