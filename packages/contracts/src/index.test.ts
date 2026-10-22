import { describe, expect, test } from "bun:test";

import { countWords, formatClock, formatTranscript } from "./index.ts";

describe("formatClock", () => {
  test("shows minutes and seconds, and hours once there are any", () => {
    expect(formatClock(0)).toBe("0:00");
    expect(formatClock(65_999)).toBe("1:05");
    expect(formatClock(3_725_000)).toBe("1:02:05");
  });
});

describe("formatTranscript", () => {
  test("puts every line on its own row with its time and speaker", () => {
    const text = formatTranscript([
      { speaker: "me", startMs: 5_000, endMs: 7_000, text: "Shall we start?" },
      { speaker: "them", startMs: 8_200, endMs: 9_000, text: "Sí, empecemos." },
    ]);
    expect(text).toBe("[0:05] me: Shall we start?\n[0:08] them: Sí, empecemos.\n");
  });
});

describe("countWords", () => {
  test("counts words across spaces and new lines", () => {
    expect(countWords("  Hola, ¿nos vemos\na las tres?  ")).toBe(6);
    expect(countWords("")).toBe(0);
  });
});
