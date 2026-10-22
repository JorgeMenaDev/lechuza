import { describe, expect, test } from "bun:test";

import type { DictationState } from "@lechuza/contracts";

import { flowBarView, meter } from "./flowBar.ts";

const idle: DictationState = {
  phase: "idle",
  error: null,
  accessibility: true,
  fnConflict: false,
  recent: [],
  stats: { words: 0, wordsPerMinute: 0 },
};

describe("flowBarView", () => {
  test("rests until hovered", () => {
    expect(flowBarView(idle, false)).toBe("idle");
    expect(flowBarView(idle, true)).toBe("hover");
  });

  test("shows what dictation is doing, ahead of an old error", () => {
    expect(flowBarView({ ...idle, phase: "listening", error: "Lechuza didn't hear anything." }, true)).toBe("listening");
    expect(flowBarView({ ...idle, phase: "handsFree" }, false)).toBe("handsFree");
    expect(flowBarView({ ...idle, phase: "transcribing" }, false)).toBe("transcribing");
    expect(flowBarView({ ...idle, error: "Lechuza didn't hear anything." }, true)).toBe("error");
  });
});

describe("meter", () => {
  test("reads loudness over the quietest recent input, across 30 dB", () => {
    let floorDb = 0;
    const read = (rms: number) => {
      const reading = meter(floorDb, rms);
      floorDb = reading.floorDb;
      return reading.level;
    };
    expect(read(0.0002)).toBe(0); // -74 dB of room tone sets the floor
    expect(read(0.0063)).toBeCloseTo(1, 1); // a whisper 30 dB above it fills the bars
    expect(read(0.0011)).toBeCloseTo(0.5, 1);
  });

  test("lets the floor rise slowly when the room gets louder, and never below -90 dB", () => {
    expect(meter(0, 0.000001).floorDb).toBe(-90);
    expect(meter(-60, 0.1).floorDb).toBeCloseTo(-59.75);
  });
});
