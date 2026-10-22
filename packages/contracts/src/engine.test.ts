import { describe, expect, test } from "bun:test";

import fixture from "../fixtures/engine-protocol.json";
import { ENGINE_COMMAND_TYPES, ENGINE_EVENT_TYPES, isEngineCommand, parseEngineEvent } from "./engine.ts";

// The Swift engine's ProtocolTests decode the same fixture, so both sides
// agree on every message.
describe("engine protocol fixture", () => {
  test("holds one valid example of every command", () => {
    expect(fixture.commands.every(isEngineCommand)).toBe(true);
    expect(fixture.commands.map((command) => command.type).sort()).toEqual([...ENGINE_COMMAND_TYPES].sort());
  });

  test("holds one valid example of every event", () => {
    const parsed: unknown[] = fixture.events.map((event) => parseEngineEvent(JSON.stringify(event)));
    expect(parsed).toEqual(fixture.events);
    expect(fixture.events.map((event) => event.type).sort()).toEqual([...ENGINE_EVENT_TYPES].sort());
  });
});

describe("parseEngineEvent", () => {
  test("rejects lines that are not well-formed events", () => {
    expect(parseEngineEvent("not json")).toBeNull();
    expect(parseEngineEvent(`{"type":"meeting.exploded"}`)).toBeNull();
    expect(parseEngineEvent(`{"type":"meeting.started","dir":"/x"}`)).toBeNull();
    expect(parseEngineEvent(`{"type":"meeting.stopped","dir":"/x","status":"great"}`)).toBeNull();
    expect(parseEngineEvent(`{"type":"meeting.level","mic":"loud","system":0}`)).toBeNull();
    expect(parseEngineEvent(`[{"type":"model.ready"}]`)).toBeNull();
  });
});
