import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import * as fs from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";

import type { EngineCommand } from "@lechuza/contracts";

import { Dictations } from "./dictation.ts";
import { DictationHistory } from "./dictationHistory.ts";

let dir: string;
let sent: EngineCommand[];
let levels: number[];
let dictations: Dictations;

beforeEach(async () => {
  dir = await fs.mkdtemp(path.join(os.tmpdir(), "lechuza-dictation-"));
  sent = [];
  levels = [];
  const history = await DictationHistory.load(path.join(dir, "dictations.jsonl"));
  dictations = new Dictations(history, { send: (command) => sent.push(command) }, "fn", {
    onState: () => {},
    onLevel: (level) => levels.push(level),
  });
});

afterEach(async () => {
  await fs.rm(dir, { recursive: true, force: true });
});

describe("Dictations", () => {
  test("configures the engine with the hotkey, and again once Accessibility is granted", () => {
    dictations.configure();
    dictations.setMac({ accessibility: false, globeDoesNothing: true });
    expect(sent).toEqual([{ type: "dictation.configure", hotkey: "fn" }]);
    dictations.setMac({ accessibility: true, globeDoesNothing: true });
    dictations.configure("rightOption");
    expect(sent.slice(1)).toEqual([
      { type: "dictation.configure", hotkey: "fn" },
      { type: "dictation.configure", hotkey: "rightOption" },
    ]);
    expect(dictations.state().accessibility).toBe(true);
  });

  test("keeps each dictation in the history and the stats", async () => {
    await dictations.handle({
      type: "dictation.done",
      text: "See you at three.",
      startedAt: "2026-10-22T14:07:31Z",
      durationMs: 1_500,
    });
    const state = dictations.state();
    expect(state.recent.map((item) => item.text)).toEqual(["See you at three."]);
    expect(state.stats).toEqual({ count: 1, words: 4, wordsPerMinute: 160 });
    const saved = await DictationHistory.load(path.join(dir, "dictations.jsonl"));
    expect(saved.recent()[0]?.text).toBe("See you at three.");
  });

  test("shows a failure on the Flow bar until the next dictation starts", async () => {
    await dictations.handle({ type: "dictation.failed", message: "Lechuza didn't hear anything." });
    expect(dictations.state().error).toBe("Lechuza didn't hear anything.");
    await dictations.handle({ type: "dictation.state", phase: "listening" });
    expect(dictations.state()).toMatchObject({ phase: "listening", error: null });
  });

  test("passes the microphone level on without a new state", async () => {
    await dictations.handle({ type: "dictation.level", level: 0.25 });
    expect(levels).toEqual([0.25]);
  });

  test("flags fn while macOS's 🌐 key setting also acts on it", () => {
    dictations.setMac({ accessibility: true, globeDoesNothing: false });
    expect(dictations.state().fnConflict).toBe(true);
    dictations.configure("rightOption");
    expect(dictations.state().fnConflict).toBe(false);
  });

  test("goes idle when the engine stops", async () => {
    await dictations.handle({ type: "dictation.state", phase: "handsFree" });
    dictations.engineExited();
    expect(dictations.state().phase).toBe("idle");
  });
});
