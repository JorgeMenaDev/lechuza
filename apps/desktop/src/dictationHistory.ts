import * as fs from "node:fs/promises";

import { countWords, type Dictation, type DictationStats } from "@lechuza/contracts";

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

// Every dictation, kept in dictations.jsonl in the app's data folder: one
// JSON object a line, appended as each one lands, so a crash loses at most
// the line being written. Unreadable lines are skipped.
export class DictationHistory {
  private constructor(
    private readonly file: string,
    // Oldest first, as on disk.
    private readonly entries: Dictation[],
  ) {}

  static async load(file: string): Promise<DictationHistory> {
    const text = await fs.readFile(file, "utf8").catch(() => "");
    const entries = text.split("\n").flatMap((line) => parseLine(line) ?? []);
    return new DictationHistory(file, entries);
  }

  async add(entry: Dictation): Promise<void> {
    this.entries.push(entry);
    await fs.appendFile(this.file, `${JSON.stringify(entry)}\n`);
  }

  // The latest `count`, newest first.
  recent(count: number): Dictation[] {
    return this.entries.slice(-count).reverse();
  }

  find(id: string): Dictation | undefined {
    return this.entries.find((entry) => entry.id === id);
  }

  stats(): DictationStats {
    return dictationStats(this.entries);
  }
}

export function dictationStats(entries: ReadonlyArray<Dictation>): DictationStats {
  const words = entries.reduce((total, entry) => total + countWords(entry.text), 0);
  const minutes = entries.reduce((total, entry) => total + entry.durationMs, 0) / 60_000;
  return { words, wordsPerMinute: minutes > 0 ? Math.round(words / minutes) : 0 };
}
