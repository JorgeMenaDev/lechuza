import { describe, expect, test } from "bun:test";

import type { TranscriptLine } from "@lechuza/contracts";

import { activeLineIndex } from "./transcript.ts";

const lines: TranscriptLine[] = [
  { speaker: "me", startMs: 1_000, endMs: 3_000, text: "Shall we start?" },
  { speaker: "them", startMs: 2_500, endMs: 4_000, text: "Sí." },
  { speaker: "me", startMs: 8_000, endMs: 9_000, text: "Great." },
];

describe("activeLineIndex", () => {
  test("is the line that started last at the playback time", () => {
    expect(activeLineIndex(lines, 1_500)).toBe(0);
    expect(activeLineIndex(lines, 2_600)).toBe(1);
    expect(activeLineIndex(lines, 9_500)).toBe(2);
  });

  test("stays on the previous line through a pause", () => {
    expect(activeLineIndex(lines, 6_000)).toBe(1);
  });

  test("is -1 before anyone speaks", () => {
    expect(activeLineIndex(lines, 500)).toBe(-1);
    expect(activeLineIndex([], 500)).toBe(-1);
  });
});
