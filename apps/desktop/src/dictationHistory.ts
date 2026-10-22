import * as fs from "node:fs/promises";

import { countWords, type Dictation, type DictationStats } from "@lechuza/contracts";

// How many of the latest dictations stay in memory and ride along in AppState.
const RECENT = 100;

function isDictation(value: unknown): value is Dictation {
  if (typeof value !== "object" || value === null) return false;
  const entry: Partial<Record<keyof Dictation, unknown>> = value;
  return (
    typeof entry.id === "string" &&
    typeof entry.text === "string" &&
    typeof entry.startedAt === "string" &&
    typeof entry.durationMs === "number"
  );
}

function parseLine(line: string): Dictation | null {
  try {
    const value: unknown = JSON.parse(line);
    return isDictation(value) ? value : null;
  } catch {
    return null;
  }
}

// Every readable dictation in the file, oldest first.
function parse(text: string): Dictation[] {
  return text.split("\n").flatMap((line) => parseLine(line) ?? []);
}

interface Totals {
  count: number;
  words: number;
  durationMs: number;
}

// Every dictation, kept in dictations.jsonl in the app's data folder: one
// JSON object a line, appended as each one lands, so a crash loses at most
// the line being written. Unreadable lines are skipped. Only the latest
// hundred and running totals stay in memory; older ones are read from disk
// when Home asks for them.
export class DictationHistory {
  private constructor(
    private readonly file: string,
    // The latest RECENT, oldest first, as on disk.
    private latest: Dictation[],
    private readonly totals: Totals,
    // The file ends in a line a crash cut short, with no newline after it.
    private torn: boolean,
  ) {}

  static async load(file: string): Promise<DictationHistory> {
    const text = await fs.readFile(file, "utf8").catch(() => "");
    const entries = parse(text);
    const totals: Totals = { count: 0, words: 0, durationMs: 0 };
    for (const entry of entries) {
      totals.count += 1;
      totals.words += countWords(entry.text);
      totals.durationMs += entry.durationMs;
    }
    return new DictationHistory(file, entries.slice(-RECENT), totals, text !== "" && !text.endsWith("\n"));
  }

  async add(entry: Dictation): Promise<void> {
    // After a torn line, the newline first, so this entry gets a line of its own.
    await fs.appendFile(this.file, `${this.torn ? "\n" : ""}${JSON.stringify(entry)}\n`);
    this.torn = false;
    this.latest = [...this.latest, entry].slice(-RECENT);
    this.totals.count += 1;
    this.totals.words += countWords(entry.text);
    this.totals.durationMs += entry.durationMs;
  }

  // The latest hundred, newest first.
  recent(): Dictation[] {
    return this.latest.toReversed();
  }

  // The newest `count`, newest first, read from disk: Home's "Show more".
  async newest(count: number): Promise<Dictation[]> {
    if (count <= this.latest.length) return this.recent().slice(0, count);
    const entries = parse(await fs.readFile(this.file, "utf8").catch(() => ""));
    return entries.slice(-count).reverse();
  }

  async find(id: string): Promise<Dictation | undefined> {
    const matches = (entry: Dictation) => entry.id === id;
    return this.latest.find(matches) ?? parse(await fs.readFile(this.file, "utf8").catch(() => "")).find(matches);
  }

  stats(): DictationStats {
    const { count, words, durationMs } = this.totals;
    const minutes = durationMs / 60_000;
    return { count, words, wordsPerMinute: minutes > 0 ? Math.round(words / minutes) : 0 };
  }
}
