import type { TranscriptLine } from "@lechuza/contracts";

// The line to highlight at a playback time: the last one to have started, so
// the highlight holds through pauses. -1 before the first line. Lines are in
// start order.
export function activeLineIndex(lines: ReadonlyArray<TranscriptLine>, ms: number): number {
  return lines.findLastIndex((line) => line.startMs <= ms);
}
