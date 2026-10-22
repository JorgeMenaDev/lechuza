import type { DictationState } from "@lechuza/contracts";

// What the Flow bar shows: resting, hovered, listening (key held), hands-free,
// transcribing, or the latest failure.
export type FlowBarView = "idle" | "hover" | "listening" | "handsFree" | "transcribing" | "error";

export function flowBarView(dictation: DictationState, hover: boolean): FlowBarView {
  if (dictation.phase !== "idle") return dictation.phase;
  if (dictation.error) return "error";
  return hover ? "hover" : "idle";
}

// How far the floor rises per reading when the room gets louder.
const FLOOR_RISE_DB = 0.25;
// A quiet room with the input volume turned down reads about -75 dB.
const LOWEST_FLOOR_DB = -90;
const SPAN_DB = 30;

// The waveform's level (0–1) from one microphone reading (RMS): the loudness
// in decibels above a floor that follows the quietest recent input, across
// 30 dB. So a whisper in a quiet room moves the bars as much as speech in a
// loud one. Start each dictation at floor 0.
export function meter(floorDb: number, rms: number): { floorDb: number; level: number } {
  const db = 20 * Math.log10(rms + 1e-9);
  const floor = Math.max(LOWEST_FLOOR_DB, Math.min(db, floorDb + FLOOR_RISE_DB));
  return { floorDb: floor, level: Math.min(Math.max((db - floor) / SPAN_DB, 0), 1) };
}
