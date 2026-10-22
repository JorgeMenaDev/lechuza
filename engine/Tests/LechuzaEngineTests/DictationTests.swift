import AppKit
import Synchronization
import XCTest

@testable import LechuzaEngine

/// A microphone that hears nothing and can be lost on demand.
final class FakeMicrophone: DictationMicrophone, @unchecked Sendable {
    private(set) var stopped = false
    private var onLost: (@Sendable () -> Void)?

    func start(onLevel: @escaping @Sendable (Float) -> Void, onLost: @escaping @Sendable () -> Void) throws {
        self.onLost = onLost
    }

    func stop() -> DictationCapture.Recording {
        stopped = true
        return DictationCapture.Recording(samples: [], sampleRate: 16_000)
    }

    /// macOS stops the capture, as a microphone change does.
    func lose() {
        onLost?()
    }
}

/// Hears each dictation as the next of `texts`.
final class FakeSpeech: DictationSpeech {
    private let texts: Mutex<[String]>

    init(_ texts: [String]) {
        self.texts = Mutex(texts)
    }

    func warmUp() async throws {}

    /// The next text, or silence once they run out.
    func transcribe(_ recording: DictationCapture.Recording) async throws -> String {
        texts.withLock { $0.isEmpty ? "" : $0.removeFirst() }
    }
}

extension EventLog {
    var phase: DictationPhase? {
        all.compactMap { if case .dictationState(let phase) = $0 { phase } else { nil } }.last
    }

    var saved: [String] {
        all.compactMap { if case .dictationDone(let text, _, _) = $0 { text } else { nil } }
    }

    var failures: [String] {
        all.compactMap { if case .dictationFailed(let message) = $0 { message } else { nil } }
    }
}

/// Dictation from key input to paste, with a fake microphone and speech and
/// a private pasteboard. Times are seconds.
@MainActor
final class DictationTests: XCTestCase {
    private var pasteboard: NSPasteboard!
    private var events: EventLog!
    private var microphones: [FakeMicrophone] = []
    private var frontmost: pid_t = 100
    /// What the clipboard held at each ⌘V.
    private var pasted: [String] = []

    override func setUp() async throws {
        pasteboard = NSPasteboard(name: .init("app.lechuza.test.\(UUID().uuidString)"))
        events = EventLog()
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
    }

    private func dictation(hearing texts: [String]) -> Dictation {
        let paster = Paster(
            system: Paster.System(
                trusted: { true },
                frontmostApp: { [unowned self] in frontmost },
                pressCommandV: { [unowned self] in
                    pasted.append(pasteboard.string(forType: .string) ?? "")
                    return true
                },
                pasteboard: pasteboard),
            holdFor: .milliseconds(50))
        return Dictation(
            emit: { [events] in events!.append($0) },
            speech: FakeSpeech(texts),
            microphone: { [unowned self] in
                let microphone = FakeMicrophone()
                microphones.append(microphone)
                return microphone
            },
            keyTap: { _, _ in nil },
            paster: paster)
    }

    private func until(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func testAHoldIsPastedAndSaved() async {
        let dictation = dictation(hearing: ["See you at three."])
        dictation.handle(.press, at: 0)
        dictation.handle(.release, at: 1)
        XCTAssertEqual(events.phase, .transcribing)
        await until { events.phase == .idle }
        XCTAssertEqual(pasted, ["See you at three."])
        XCTAssertEqual(events.saved, ["See you at three."])
    }

    /// The thrown-away recording never reaches speech recognition, so the
    /// only text heard goes to the dictation that was kept.
    func testEscWhileTranscribingPastesNothing() async {
        let dictation = dictation(hearing: ["Kept."])
        dictation.handle(.press, at: 0)
        dictation.handle(.release, at: 1)
        dictation.handle(.escape, at: 1.05)
        XCTAssertEqual(events.phase, .idle)
        dictation.handle(.press, at: 2)
        dictation.handle(.release, at: 3)
        await until { events.saved.count == 1 && events.phase == .idle }
        XCTAssertEqual(pasted, ["Kept."])
        XCTAssertEqual(events.saved, ["Kept."])
    }

    func testALostMicrophoneStopsTheDictationAndSaysSo() async {
        let dictation = dictation(hearing: ["Never heard."])
        dictation.start()
        XCTAssertEqual(events.phase, .handsFree)
        microphones[0].lose()
        await until { !events.failures.isEmpty }
        XCTAssertEqual(events.phase, .idle)
        XCTAssertTrue(microphones[0].stopped)
        XCTAssertTrue(events.failures.first?.contains("microphone") == true, "\(events.failures)")
        XCTAssertEqual(pasted, [])
    }

    func testChangingTheKeyMidDictationThrowsItAwayAndStartsAfresh() async {
        let dictation = dictation(hearing: ["Next one."])
        dictation.start()
        dictation.configure(hotkey: .rightOption)
        XCTAssertEqual(events.phase, .idle)
        XCTAssertTrue(microphones[0].stopped)
        dictation.handle(.press, at: 10)
        dictation.handle(.release, at: 11)
        await until { events.phase == .idle && !pasted.isEmpty }
        XCTAssertEqual(pasted, ["Next one."])
    }

    func testWordsForAnAppThatLostTheFrontAreSavedNotPasted() async {
        let dictation = dictation(hearing: ["For the other app."])
        dictation.handle(.press, at: 0)
        dictation.handle(.release, at: 1)
        frontmost = 200
        await until { !events.failures.isEmpty }
        XCTAssertEqual(pasted, [])
        XCTAssertEqual(events.saved, ["For the other app."])
        XCTAssertTrue(events.failures.first?.contains("Saved in Lechuza") == true, "\(events.failures)")
    }
}
