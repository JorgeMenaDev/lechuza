// Shared types between the Electron main process, the preload bridge and the
// React renderer. Main owns all state; renderers read it through
// `LechuzaBridge` and send intents back.

import type { DictationPhase, Hotkey, ModelPhase } from "./engine.ts";

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

// The meeting side of AppState, owned by `Meetings` in main.
export interface MeetingsState {
  readonly phase: RecorderPhase;
  // The meeting being recorded, with its start in epoch milliseconds.
  readonly recording: { readonly id: string; readonly startedAt: number } | null;
  readonly model: ModelStatus;
  // The latest error or warning for the user, until dismissed.
  readonly notice: string | null;
  // Newest first.
  readonly meetings: ReadonlyArray<Meeting>;
}

// "system" follows the macOS appearance.
export type Theme = "system" | "light" | "dark";

// What the user chose in Settings, saved in the app's data folder.
export interface Settings {
  readonly theme: Theme;
  // The key that starts dictation.
  readonly hotkey: Hotkey;
  // Start and stop sounds around each dictation.
  readonly sounds: boolean;
}

// One dictation in the history, saved in the app's data folder.
export interface Dictation {
  readonly id: string;
  readonly text: string;
  readonly startedAt: string;
  // How long the user spoke.
  readonly durationMs: number;
}

export interface DictationStats {
  readonly words: number;
  // Words per minute of speaking, or 0 before the first dictation.
  readonly wordsPerMinute: number;
}

// The dictation side of AppState, owned by `Dictations` in main.
export interface DictationState {
  readonly phase: DictationPhase;
  // The latest failure, shown on the Flow bar for a few seconds.
  readonly error: string | null;
  // Lechuza may listen for the hotkey and paste (Accessibility).
  readonly accessibility: boolean;
  // macOS's "Press 🌐 key to" setting also acts on fn: the hotkey is fn and
  // that setting isn't "Do Nothing".
  readonly fnConflict: boolean;
  // Newest first, the latest hundred.
  readonly recent: ReadonlyArray<Dictation>;
  // Over the whole history.
  readonly stats: DictationStats;
}

// Facts about the app and this Mac that don't change while it runs.
export interface AppInfo {
  readonly version: string;
  // Where meetings are saved.
  readonly meetingsDir: string;
  // The Mac user's first name for the greeting, or null when unknown.
  readonly firstName: string | null;
}

export interface AppState extends MeetingsState {
  readonly dictation: DictationState;
  readonly settings: Settings;
  readonly info: AppInfo;
}

// Pages outside the app that Settings links to.
export type ExternalPage =
  | "repository"
  | "sound-settings"
  | "privacy-microphone"
  | "privacy-system-audio"
  | "privacy-documents"
  | "privacy-accessibility"
  | "keyboard-settings";

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
  // The microphone's loudness (RMS, 0–1) while dictating; only the Flow bar gets it.
  onDictationLevel(listener: (level: number) => void): Unsubscribe;
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
  setTheme(theme: Theme): Promise<void>;
  setHotkey(hotkey: Hotkey): Promise<void>;
  setSounds(on: boolean): Promise<void>;
  // Starts hands-free dictation from the Flow bar; stopDictation inserts it.
  startDictation(): Promise<void>;
  stopDictation(): Promise<void>;
  copyDictation(id: string): Promise<void>;
  // Shows macOS's Accessibility prompt for Lechuza.
  requestAccessibility(): Promise<void>;
  // The pointer is over the Flow bar's pill: it takes clicks until it leaves.
  setFlowBarHover(hover: boolean): Promise<void>;
  revealMeetingsFolder(): Promise<void>;
  openExternal(page: ExternalPage): Promise<void>;
}

export const IPC = {
  state: "lechuza:state",
  getState: "lechuza:get-state",
  levels: "lechuza:levels",
  dictationLevel: "lechuza:dictation-level",
  startMeeting: "lechuza:start-meeting",
  stopMeeting: "lechuza:stop-meeting",
  getTranscript: "lechuza:get-transcript",
  copyTranscript: "lechuza:copy-transcript",
  renameMeeting: "lechuza:rename-meeting",
  trashMeeting: "lechuza:trash-meeting",
  revealMeeting: "lechuza:reveal-meeting",
  retryTranscription: "lechuza:retry-transcription",
  dismissNotice: "lechuza:dismiss-notice",
  setTheme: "lechuza:set-theme",
  setHotkey: "lechuza:set-hotkey",
  setSounds: "lechuza:set-sounds",
  startDictation: "lechuza:start-dictation",
  stopDictation: "lechuza:stop-dictation",
  copyDictation: "lechuza:copy-dictation",
  requestAccessibility: "lechuza:request-accessibility",
  setFlowBarHover: "lechuza:set-flow-bar-hover",
  revealMeetingsFolder: "lechuza:reveal-meetings-folder",
  openExternal: "lechuza:open-external",
} as const;

// lechuza-media://meeting/<id> serves that meeting's mix, with byte ranges.
export const MEDIA_SCHEME = "lechuza-media";

// Every window loads the same bundle; `#/<surface>` picks the screen.
export type Surface = "main" | "flow-bar";

// "1:05", or "1:02:05" past the hour.
export function formatClock(ms: number): string {
  const total = Math.floor(ms / 1000);
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const seconds = String(total % 60).padStart(2, "0");
  return hours > 0 ? `${hours}:${String(minutes).padStart(2, "0")}:${seconds}` : `${minutes}:${seconds}`;
}

// Words in a dictation, however it is spaced.
export function countWords(text: string): number {
  return text.split(/\s+/).filter(Boolean).length;
}

// The plain-text transcript Copy transcript puts on the clipboard.
export function formatTranscript(lines: ReadonlyArray<TranscriptLine>): string {
  return lines.map((line) => `[${formatClock(line.startMs)}] ${line.speaker}: ${line.text}\n`).join("");
}
