import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import * as fs from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";

import type { EngineCommand, Levels } from "@lechuza/contracts";

import { MeetingLibrary } from "./library.ts";
import { Meetings } from "./meetings.ts";

let root: string;
let sent: EngineCommand[];
let levels: Levels[];
let meetings: Meetings;

const dir = (id: string) => path.join(root, id);

async function finishedSession(id: string): Promise<void> {
  await fs.mkdir(dir(id), { recursive: true });
  await fs.writeFile(
    path.join(dir(id), "meta.json"),
    JSON.stringify({ schema_version: 2, started: "2026-10-22T09:00:00Z", duration_seconds: 60, tracks: [] }),
  );
}

beforeEach(async () => {
  root = await fs.mkdtemp(path.join(os.tmpdir(), "lechuza-meetings-"));
  sent = [];
  levels = [];
  meetings = new Meetings(new MeetingLibrary(root), { send: (command) => sent.push(command) }, {
    onState: () => {},
    onLevels: (value) => levels.push(value),
  });
});

afterEach(async () => {
  await fs.rm(root, { recursive: true, force: true });
});

describe("Meetings", () => {
  test("starts a meeting and fetches the model while it records", async () => {
    await meetings.handle({ type: "ready", modelDownloaded: false });
    meetings.start();
    expect(sent).toEqual([{ type: "meeting.start", root }]);
    expect((await meetings.state()).phase).toBe("starting");

    await fs.mkdir(dir("2026-10-22-1405"));
    await meetings.handle({ type: "meeting.started", dir: dir("2026-10-22-1405"), startedAt: "2026-10-22T14:05:09Z" });
    const state = await meetings.state();
    expect(state.phase).toBe("recording");
    expect(state.recording).toEqual({ id: "2026-10-22-1405", startedAt: Date.parse("2026-10-22T14:05:09Z") });
    expect(state.meetings.map((meeting) => meeting.state)).toEqual(["recording"]);
    expect(sent.at(-1)).toEqual({ type: "model.prepare" });

    await meetings.handle({ type: "meeting.level", mic: 0.5, system: 0.25 });
    expect(levels).toEqual([{ mic: 0.5, system: 0.25 }]);
  });

  test("transcribes stopped meetings one at a time", async () => {
    await finishedSession("2026-10-22-0900");
    await finishedSession("2026-10-22-1000");
    await meetings.handle({ type: "meeting.stopped", dir: dir("2026-10-22-0900"), status: "complete" });
    meetings.retry("2026-10-22-1000");
    expect(sent).toEqual([{ type: "transcription.start", dir: dir("2026-10-22-0900") }]);
    expect((await meetings.state()).meetings.map((meeting) => meeting.state)).toEqual(["transcribing", "transcribing"]);

    await meetings.handle({ type: "transcription.done", dir: dir("2026-10-22-0900") });
    expect(sent.at(-1)).toEqual({ type: "transcription.start", dir: dir("2026-10-22-1000") });
  });

  test("a meeting that can't start leaves a notice until dismissed", async () => {
    meetings.start();
    await meetings.handle({ type: "meeting.failed", message: "Lechuza can't use the microphone." });
    expect(await meetings.state()).toMatchObject({ phase: "idle", notice: "Lechuza can't use the microphone." });
    meetings.dismissNotice();
    expect((await meetings.state()).notice).toBeNull();
  });

  test("follows the model download", async () => {
    await meetings.handle({ type: "ready", modelDownloaded: false });
    expect((await meetings.state()).model).toEqual({ state: "missing" });
    await meetings.handle({ type: "model.progress", phase: "downloading", fraction: 0.42 });
    expect((await meetings.state()).model).toEqual({ state: "downloading", phase: "downloading", fraction: 0.42 });
    await meetings.handle({ type: "model.ready" });
    expect((await meetings.state()).model).toEqual({ state: "ready" });
  });

  test("resumes meetings whose transcription was cut short", async () => {
    await finishedSession("2026-10-21-1500");
    await meetings.handle({ type: "ready", modelDownloaded: true });
    expect(sent).toEqual([{ type: "transcription.start", dir: dir("2026-10-21-1500") }]);
  });

  test("the launch scan leaves alone a meeting that started while it ran", async () => {
    await fs.mkdir(dir("2026-10-22-1405"));
    await fs.writeFile(path.join(dir("2026-10-22-1405"), "recording.json"), "{}");
    meetings.start();
    const scan = meetings.handle({ type: "ready", modelDownloaded: true });
    await meetings.handle({ type: "meeting.started", dir: dir("2026-10-22-1405"), startedAt: "2026-10-22T14:05:09Z" });
    await scan;
    expect(sent).toEqual([{ type: "meeting.start", root }]);
  });

  test("marks the transcription failed when the engine dies on it", async () => {
    await finishedSession("2026-10-22-0900");
    await meetings.handle({ type: "meeting.stopped", dir: dir("2026-10-22-0900"), status: "complete" });
    await meetings.engineExited();
    const [meeting] = (await meetings.state()).meetings;
    expect(meeting?.state).toBe("failed");
    expect(meeting?.error).toBe("The engine stopped while transcribing.");
  });

  test("recovers from an engine death even when the failure can't be written", async () => {
    await finishedSession("2026-10-22-0900");
    await finishedSession("2026-10-22-1000");
    await meetings.handle({ type: "meeting.stopped", dir: dir("2026-10-22-0900"), status: "complete" });
    // The folder went to the Trash mid-transcription, so the failure marker has nowhere to go.
    await fs.rm(dir("2026-10-22-0900"), { recursive: true });
    await meetings.engineExited();

    meetings.retry("2026-10-22-1000");
    expect(sent.at(-1)).toEqual({ type: "transcription.start", dir: dir("2026-10-22-1000") });
  });
});
