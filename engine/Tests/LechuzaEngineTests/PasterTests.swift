import AppKit
import XCTest

@testable import LechuzaEngine

/// Pasting a dictation: only with Accessibility, only into the app that had
/// focus when it stopped, and with the clipboard put back once the words
/// have had time to land. A private pasteboard stands in for the clipboard.
@MainActor
final class PasterTests: XCTestCase {
    private var pasteboard: NSPasteboard!
    private var trusted = true
    private var frontmost: pid_t = 100
    private var keystrokeWorks = true
    private var keystrokes = 0
    /// What the app that gets the ⌘V does with it.
    private var app: () -> Void = {}

    override func setUp() async throws {
        pasteboard = NSPasteboard(name: .init("app.lechuza.test.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("copied before", forType: .string)
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
    }

    private func paster(holdFor: Duration = .milliseconds(300)) -> Paster {
        Paster(
            system: Paster.System(
                trusted: { [unowned self] in trusted },
                frontmostApp: { [unowned self] in frontmost },
                pressCommandV: { [unowned self] in
                    keystrokes += 1
                    app()
                    return keystrokeWorks
                },
                pasteboard: pasteboard),
            holdFor: holdFor)
    }

    /// Waits until the clipboard holds `text`, or gives up after 3 s.
    private func clipboard(becomes text: String) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while pasteboard.string(forType: .string) != text, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return pasteboard.string(forType: .string) == text
    }

    /// A clipboard manager reads every change at once; the app that got the
    /// ⌘V reads later. The words must still be there for the app.
    func testAClipboardManagerReadingFirstDoesNotTakeTheWordsFromASlowApp() async {
        var pasted: String?
        let read = expectation(description: "the app read the clipboard")
        app = { [pasteboard] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { _ = pasteboard?.string(forType: .string) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                pasted = pasteboard?.string(forType: .string)
                read.fulfill()
            }
        }
        let paster = paster(holdFor: .seconds(1))
        XCTAssertEqual(paster.paste("dictated words", into: 100), .pasted)
        await fulfillment(of: [read])
        XCTAssertEqual(pasted, "dictated words")
        let restored = await clipboard(becomes: "copied before")
        XCTAssertTrue(restored)
    }

    /// The next dictation can paste before the last one's hold ends: it must
    /// save the user's clipboard, never the last dictation's words.
    func testBackToBackPastesGiveBackTheUsersClipboard() async {
        let paster = paster()
        XCTAssertEqual(paster.paste("first", into: 100), .pasted)
        XCTAssertEqual(paster.paste("second", into: 100), .pasted)
        XCTAssertEqual(pasteboard.string(forType: .string), "second")
        let restored = await clipboard(becomes: "copied before")
        XCTAssertTrue(restored)
    }

    func testWithoutAccessibilityTheClipboardIsNeverTouched() async {
        trusted = false
        let before = pasteboard.changeCount
        let paster = paster()
        XCTAssertEqual(paster.paste("dictated words", into: 100), .noAccessibility)
        XCTAssertEqual(keystrokes, 0)
        XCTAssertEqual(pasteboard.changeCount, before)
        XCTAssertEqual(pasteboard.string(forType: .string), "copied before")
    }

    func testNothingIsPastedIntoAnAppThatCameToTheFrontSince() {
        let paster = paster()
        let target = paster.target()
        frontmost = 200
        let before = pasteboard.changeCount
        XCTAssertEqual(paster.paste("dictated words", into: target), .appChanged)
        XCTAssertEqual(keystrokes, 0)
        XCTAssertEqual(pasteboard.changeCount, before)
    }

    func testAKeystrokeMacOSWontMakeLeavesTheClipboardAsItWas() {
        keystrokeWorks = false
        XCTAssertEqual(paster().paste("dictated words", into: 100), .failed)
        XCTAssertEqual(pasteboard.string(forType: .string), "copied before")
    }
}
