import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import * as fs from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";

import type { Dictation } from "@lechuza/contracts";

import { DictationHistory } from "./dictationHistory.ts";

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
    expect(history.recent()).toEqual([]);
    await history.add(dictation("1", "First one.", 2));
    await history.add(dictation("2", "Second one.", 2));
    await history.add(dictation("3", "Third one.", 2));

    const reloaded = await DictationHistory.load(file);
    expect(reloaded.recent().map((item) => item.id)).toEqual(["3", "2", "1"]);
    expect((await reloaded.find("1"))?.text).toBe("First one.");
  });

  test("skips a line torn by a crash mid-write", async () => {
    await fs.writeFile(file, `${JSON.stringify(dictation("1", "Kept.", 1))}\n{"id":"2","te\n`);
    const history = await DictationHistory.load(file);
    expect(history.recent().map((item) => item.id)).toEqual(["1"]);
  });

  test("the next dictation after a torn last line starts a line of its own", async () => {
    await fs.writeFile(file, `${JSON.stringify(dictation("1", "Kept.", 1))}\n{"id":"2","te`);
    await (await DictationHistory.load(file)).add(dictation("3", "After the crash.", 1));
    const reloaded = await DictationHistory.load(file);
    expect(reloaded.recent().map((item) => item.id)).toEqual(["3", "1"]);
  });

  test("keeps the latest hundred in memory and reads older ones from disk", async () => {
    const history = await DictationHistory.load(file);
    for (let n = 1; n <= 105; n++) await history.add(dictation(String(n), "One two three.", 1));

    expect(history.recent()).toHaveLength(100);
    expect(history.recent()[0]?.id).toBe("105");
    const all = await history.newest(200);
    expect(all.map((item) => item.id)).toEqual(Array.from({ length: 105 }, (_, n) => String(105 - n)));
    expect(await history.newest(2)).toEqual(history.recent().slice(0, 2));
    expect((await history.find("1"))?.id).toBe("1");
  });

  test("adds up words and words per minute over the whole history", async () => {
    await fs.writeFile(file, `${JSON.stringify(dictation("1", "Hola, ¿nos vemos a las tres?", 3))}\n`);
    const history = await DictationHistory.load(file);
    await history.add(dictation("2", "See you   there.", 3));
    expect(history.stats()).toEqual({ count: 2, words: 9, wordsPerMinute: 90 });
  });

  test("its stats are zero before the first dictation", async () => {
    expect((await DictationHistory.load(file)).stats()).toEqual({ count: 0, words: 0, wordsPerMinute: 0 });
  });
});
