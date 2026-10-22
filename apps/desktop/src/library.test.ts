import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import * as fs from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";

import { MeetingLibrary } from "./library.ts";

let root: string;
let library: MeetingLibrary;
const idle = { recording: null, transcribing: new Set<string>() };

// A finished session folder as the engine writes it.
async function session(id: string, files: Record<string, string | object>): Promise<void> {
  await fs.mkdir(path.join(root, id), { recursive: true });
  for (const [name, content] of Object.entries(files)) {
    const text = typeof content === "string" ? content : JSON.stringify(content);
    await fs.writeFile(path.join(root, id, name), text);
  }
}

function meta(started: string, durationSeconds: number, extra: object = {}): object {
  return { schema_version: 2, started, ended: started, duration_seconds: durationSeconds, status: "complete", tracks: [], ...extra };
}

const transcript = {
  engine: "parakeet",
  model: "parakeet-tdt-0.6b-v3-coreml",
  created_at: "2026-10-20T09:31:00Z",
  segments: [
    { speaker: "me", start_ms: 1200, end_ms: 2900, text: "Morning, everyone." },
    { speaker: "them", start_ms: 3100, end_ms: 4000, text: "Buenos días." },
  ],
};

beforeEach(async () => {
  root = await fs.mkdtemp(path.join(os.tmpdir(), "lechuza-library-"));
  library = new MeetingLibrary(root);
});

afterEach(async () => {
  await fs.rm(root, { recursive: true, force: true });
});

describe("MeetingLibrary.list", () => {
  test("lists meetings newest first with their title, date, duration and state", async () => {
    await session("2026-10-20-0900", {
      "meta.json": meta("2026-10-20T09:00:05Z", 1800, { title: "Standup" }),
      "transcript.json": transcript,
      "meeting.m4a": "audio",
    });
    await session("2026-10-21-1000", {
      "meta.json": meta("2026-10-21T10:00:00Z", 60),
      "meeting.m4a": "audio",
      "transcript-error.txt": "No audio was recorded.\n",
    });
    await session("2026-10-21-1500", { "meta.json": meta("2026-10-21T15:00:00Z", 600), "meeting.m4a": "audio" });
    await session("2026-10-22-1405", { "mic.caf": "live" });

    const meetings = await library.list({
      recording: { id: "2026-10-22-1405", startedAt: Date.parse("2026-10-22T14:05:09Z") },
      transcribing: new Set(["2026-10-21-1500"]),
    });

    expect(meetings.map(({ id, state, durationMs, error }) => ({ id, state, durationMs, error }))).toEqual([
      { id: "2026-10-22-1405", state: "recording", durationMs: 0, error: null },
      { id: "2026-10-21-1500", state: "transcribing", durationMs: 600_000, error: null },
      { id: "2026-10-21-1000", state: "failed", durationMs: 60_000, error: "No audio was recorded." },
      { id: "2026-10-20-0900", state: "ready", durationMs: 1_800_000, error: null },
    ]);
    expect(meetings[3]?.title).toBe("Standup");
    expect(meetings[3]?.startedAt).toBe("2026-10-20T09:00:05Z");
    expect(meetings[3]?.audioUrl).toStartWith("lechuza-media://meeting/2026-10-20-0900?v=");
    expect(meetings[0]?.startedAt).toBe("2026-10-22T14:05:09.000Z");
    expect(meetings[0]?.audioUrl).toBeNull();
  });

  test("a folder the engine never finished is failed, with a reason", async () => {
    await session("2026-10-22-0800", { "mic.caf": "cut short" });
    const [meeting] = await library.list(idle);
    expect(meeting?.state).toBe("failed");
    expect(meeting?.error).toBe("The recording stopped before it was saved.");
  });

  test("a transcript that only partly worked is failed, so it can be retried", async () => {
    await session("2026-10-22-0800", {
      "meta.json": meta("2026-10-22T08:00:00Z", 60),
      "transcript.json": transcript,
      "transcript-error.txt": "Couldn't transcribe system.aac: unreadable audio\n",
    });
    const [meeting] = await library.list(idle);
    expect(meeting?.state).toBe("failed");
    expect(meeting?.error).toBe("Couldn't transcribe system.aac: unreadable audio");
  });

  test("leaves out anything that isn't a meeting folder", async () => {
    await fs.writeFile(path.join(root, ".DS_Store"), "");
    await session("Notes", {});
    expect(await library.list(idle)).toEqual([]);
  });

  test("works before the meetings folder exists", async () => {
    expect(await new MeetingLibrary(path.join(root, "missing")).list(idle)).toEqual([]);
  });
});

describe("MeetingLibrary", () => {
  test("renames a meeting and keeps the engine's metadata", async () => {
    await session("2026-10-20-0900", { "meta.json": meta("2026-10-20T09:00:05Z", 1800) });
    await library.rename("2026-10-20-0900", "  Weekly sync  ");
    const [meeting] = await library.list(idle);
    expect(meeting?.title).toBe("Weekly sync");
    const saved = JSON.parse(await fs.readFile(path.join(root, "2026-10-20-0900", "meta.json"), "utf8"));
    expect(saved).toMatchObject({ schema_version: 2, duration_seconds: 1800, title: "Weekly sync" });
  });

  test("reads the transcript as me / them lines", async () => {
    await session("2026-10-20-0900", { "meta.json": meta("2026-10-20T09:00:05Z", 1800), "transcript.json": transcript });
    expect(await library.transcript("2026-10-20-0900")).toEqual([
      { speaker: "me", startMs: 1200, endMs: 2900, text: "Morning, everyone." },
      { speaker: "them", startMs: 3100, endMs: 4000, text: "Buenos días." },
    ]);
    expect(await library.transcript("2026-10-21-1000")).toEqual([]);
  });

  test("finds finished meetings that were never transcribed", async () => {
    await session("2026-10-20-0900", { "meta.json": meta("2026-10-20T09:00:05Z", 1800), "transcript.json": transcript });
    await session("2026-10-21-1000", { "meta.json": meta("2026-10-21T10:00:00Z", 60), "transcript-error.txt": "x" });
    await session("2026-10-21-1500", { "meta.json": meta("2026-10-21T15:00:00Z", 600) });
    await session("2026-10-22-1405", { "mic.caf": "live" });
    expect(await library.untranscribed()).toEqual(["2026-10-21-1500"]);
  });

  test("refuses ids that leave the meetings folder", () => {
    expect(library.dir("2026-10-20-0900")).toBe(path.join(root, "2026-10-20-0900"));
    expect(library.dir("../Documents")).toBeNull();
    expect(library.dir("2026-10-20-0900/../..")).toBeNull();
  });
});
