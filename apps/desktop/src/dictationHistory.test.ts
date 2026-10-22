import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import * as fs from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";

import type { Dictation } from "@lechuza/contracts";

import { DictationHistory, dictationStats } from "./dictationHistory.ts";

let file: string;

beforeEach(async () => {
  file = path.join(await fs.mkdtemp(path.join(os.tmpdir(), "lechuza-dictations-")), "dictations.jsonl");
});

afterEach(async () => {
  await fs.rm(path.dirname(file), { recursive: true, force: true });
});

function dictation(id: string, text: string, seconds: number): Dictation {
  return { id, text, startedAt: `2026-10-22T14:0${id}:00Z`, durationMs: seconds * 1000 };
}

describe("DictationHistory", () => {
  test("starts empty, keeps each dictation on disk, and lists the newest first", async () => {
    const history = await DictationHistory.load(file);
    expect(history.recent(10)).toEqual([]);
    await history.add(dictation("1", "First one.", 2));
    await history.add(dictation("2", "Second one.", 2));
    await history.add(dictation("3", "Third one.", 2));

    const reloaded = await DictationHistory.load(file);
    expect(reloaded.recent(2).map((item) => item.id)).toEqual(["3", "2"]);
    expect(reloaded.find("1")?.text).toBe("First one.");
  });

  test("skips a line torn by a crash mid-write", async () => {
    await fs.writeFile(file, `${JSON.stringify(dictation("1", "Kept.", 1))}\n{"id":"2","te\n`);
    const history = await DictationHistory.load(file);
    expect(history.recent(10).map((item) => item.id)).toEqual(["1"]);
  });
});

describe("dictationStats", () => {
  test("adds up words and words per minute of speaking", () => {
    const stats = dictationStats([
      dictation("1", "Hola, ¿nos vemos a las tres?", 3),
      dictation("2", "See you   there.", 3),
    ]);
    expect(stats).toEqual({ words: 9, wordsPerMinute: 90 });
  });

  test("is zero before the first dictation", () => {
    expect(dictationStats([])).toEqual({ words: 0, wordsPerMinute: 0 });
  });
});
