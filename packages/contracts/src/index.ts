// Shared types between the Electron main process, the preload bridge and the
// React renderer. Main owns all state; renderers read it through
// `LechuzaBridge` and send intents back.

import type { ModelPhase } from "./engine.ts";

export * from "./engine.ts";

// recording → transcribing (mixing, model download, transcription) → ready | failed
export type MeetingState = "recording" | "transcribing" | "ready" | "failed";

// One meeting folder in ~/Documents/Lechuza/Meetings.
export interface Meeting {
  // The folder name, e.g. "2026-10-22-1405".
  readonly id: string;
  readonly title: string;
  readonly startedAt: string;
  // 0 while recording; the renderer ticks the clock from `startedAt`.
  readonly durationMs: number;
  readonly state: MeetingState;
  // Why transcription failed, when `state` is "failed".
  readonly error: string | null;
  // The mixed recording through the media protocol, once it exists.
  readonly audioUrl: string | null;
}

export type Speaker = "me" | "them";

export interface TranscriptLine {
  readonly speaker: Speaker;
  readonly startMs: number;
  readonly endMs: number;
  readonly text: string;
}

// idle → starting → recording → stopping (saving the tracks and the mix) → idle
export type RecorderPhase = "idle" | "starting" | "recording" | "stopping";

export type ModelStatus =
  | { readonly state: "unknown" }
  | { readonly state: "missing" }
  | { readonly state: "downloading"; readonly phase: ModelPhase; readonly fraction: number }
  | { readonly state: "ready" }
  | { readonly state: "failed"; readonly message: string };

export interface AppState {
  readonly phase: RecorderPhase;
  // The meeting being recorded, with its start in epoch milliseconds.
  readonly recording: { readonly id: string; readonly startedAt: number } | null;
  readonly model: ModelStatus;
  // The latest error or warning for the user, until dismissed.
  readonly notice: string | null;
  // Newest first.
  readonly meetings: ReadonlyArray<Meeting>;
}

// Peak levels (0–1) while recording, sent apart from the state ten times a second.
export interface Levels {
  readonly mic: number;
  readonly system: number;
}

export type Unsubscribe = () => void;

// Exposed on `window.lechuza` by the preload script.
export interface LechuzaBridge {
  getState(): Promise<AppState>;
  onState(listener: (state: AppState) => void): Unsubscribe;
  onLevels(listener: (levels: Levels) => void): Unsubscribe;
  startMeeting(): Promise<void>;
  stopMeeting(): Promise<void>;
  // Empty until the meeting is transcribed.
  getTranscript(id: string): Promise<ReadonlyArray<TranscriptLine>>;
  // Puts the whole transcript on the clipboard as plain text.
  copyTranscript(id: string): Promise<void>;
  renameMeeting(id: string, title: string): Promise<void>;
  // Moves the meeting folder to the Trash.
  trashMeeting(id: string): Promise<void>;
  revealMeeting(id: string): Promise<void>;
  retryTranscription(id: string): Promise<void>;
  dismissNotice(): Promise<void>;
}

export const IPC = {
  state: "lechuza:state",
  getState: "lechuza:get-state",
  levels: "lechuza:levels",
  startMeeting: "lechuza:start-meeting",
  stopMeeting: "lechuza:stop-meeting",
  getTranscript: "lechuza:get-transcript",
  copyTranscript: "lechuza:copy-transcript",
  renameMeeting: "lechuza:rename-meeting",
  trashMeeting: "lechuza:trash-meeting",
  revealMeeting: "lechuza:reveal-meeting",
  retryTranscription: "lechuza:retry-transcription",
  dismissNotice: "lechuza:dismiss-notice",
} as const;

// lechuza-media://meeting/<id> serves that meeting's mix, with byte ranges.
export const MEDIA_SCHEME = "lechuza-media";

// Every window loads the same bundle; `#/<surface>` picks the screen.
export type Surface = "meetings";

// "1:05", or "1:02:05" past the hour.
export function formatClock(ms: number): string {
  const total = Math.floor(ms / 1000);
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const seconds = String(total % 60).padStart(2, "0");
  return hours > 0 ? `${hours}:${String(minutes).padStart(2, "0")}:${seconds}` : `${minutes}:${seconds}`;
}

// The plain-text transcript Copy transcript puts on the clipboard.
export function formatTranscript(lines: ReadonlyArray<TranscriptLine>): string {
  return lines.map((line) => `[${formatClock(line.startMs)}] ${line.speaker}: ${line.text}\n`).join("");
}
