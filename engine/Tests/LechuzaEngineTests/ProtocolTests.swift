import Foundation
import XCTest

@testable import LechuzaEngine

/// The app's contracts test decodes the same fixture, so both sides agree on
/// every message: each decodes here, encodes back to the same JSON, and
/// every message type has an example.
final class ProtocolTests: XCTestCase {
    private struct Fixture: Decodable {
        let commands: [EngineCommand]
        let events: [EngineEvent]
    }

    private let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("../../../packages/contracts/fixtures/engine-protocol.json")
        .standardized

    private func rawMessages(_ key: String) throws -> [NSDictionary] {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any]
        return try XCTUnwrap(json?[key] as? [NSDictionary])
    }

    private func reencoded<T: Encodable>(_ values: [T]) throws -> [NSDictionary] {
        try values.map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) as? NSDictionary)
        }
    }

    func testEveryCommandRoundTrips() throws {
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixtureURL))
        XCTAssertEqual(try reencoded(fixture.commands), try rawMessages("commands"))
        XCTAssertEqual(Set(fixture.commands.map(\.kind)), Set(EngineCommand.Kind.allCases))
    }

    func testEveryEventRoundTrips() throws {
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixtureURL))
        XCTAssertEqual(try reencoded(fixture.events), try rawMessages("events"))
        XCTAssertEqual(Set(fixture.events.map(\.kind)), Set(EngineEvent.Kind.allCases))
    }

    func testUnknownCommandIsReportedAsAnError() async throws {
        let events = EventLog()
        let engine = await Engine(emit: events.append)
        await engine.handle(line: #"{"type":"dictation.start"}"#)
        XCTAssertEqual(events.all, [.error(message: #"unreadable command: {"type":"dictation.start"}"#)])
    }
}

/// Collects the events an engine emits, from any thread.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [EngineEvent] = []

    var all: [EngineEvent] {
        lock.withLock { events }
    }

    func append(_ event: EngineEvent) {
        lock.withLock { events.append(event) }
    }
}
