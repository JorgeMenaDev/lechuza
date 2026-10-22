import AppKit
import XCTest

@testable import LechuzaEngine

/// Pasting a dictation: only with Accessibility, only into the app that had
/// focus when it stopped, and with the clipboard put back once that app has
/// read the words. A private pasteboard stands in for the clipboard.
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

    private func paster(readTimeout: Duration = .seconds(5)) -> Paster {
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
            readTimeout: readTimeout)
    }

    func testASlowAppStillPastesTheWordsThenTheClipboardComesBack() async {
        var pasted: String?
        let read = expectation(description: "the app read the clipboard")
        app = { [pasteboard] in
            // The app gets to the ⌘V after 700 ms, later than the old fixed restore.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                pasted = pasteboard?.string(forType: .string)
                read.fulfill()
            }
        }
        let paster = paster()
        XCTAssertEqual(paster.paste("dictated words", into: 100), .pasted)
        await paster.restoreClipboard()
        await fulfillment(of: [read])
        XCTAssertEqual(pasted, "dictated words")
        XCTAssertEqual(pasteboard.string(forType: .string), "copied before")
    }

    func testAnAppThatNeverReadsGetsTheClipboardBackAfterTheTimeout() async {
        let paster = paster(readTimeout: .milliseconds(100))
        XCTAssertEqual(paster.paste("dictated words", into: 100), .pasted)
        await paster.restoreClipboard()
        XCTAssertEqual(pasteboard.string(forType: .string), "copied before")
    }

    func testWithoutAccessibilityTheClipboardIsNeverTouched() async {
        trusted = false
        let before = pasteboard.changeCount
        let paster = paster()
        XCTAssertEqual(paster.paste("dictated words", into: 100), .noAccessibility)
        await paster.restoreClipboard()
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
