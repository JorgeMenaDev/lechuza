// The protocol between the Electron main process and `lechuza-engine`: one
// JSON object per line, commands on the engine's stdin and events on its
// stdout. The Swift side mirrors these as Codable enums in
// engine/Sources/LechuzaEngine/Protocol.swift; fixtures/engine-protocol.json
// holds one example of every message and both sides' tests decode it.
// Types are grouped by feature, so `dictation.*` can join without touching
// `meeting.*`, `model.*` or `transcription.*`.

export const TRACK_STATUSES = ["complete", "recovered", "incomplete"] as const;
export const MODEL_PHASES = ["listing", "downloading", "compiling"] as const;

export type TrackStatus = (typeof TRACK_STATUSES)[number];
export type ModelPhase = (typeof MODEL_PHASES)[number];

// A field is a JSON primitive (named by typeof) or one of a list of strings.
type FieldSpec = "string" | "number" | "boolean" | readonly string[];
type MessageSpecs = Record<string, Record<string, FieldSpec>>;

type FieldValue<S> = S extends "string"
  ? string
  : S extends "number"
    ? number
    : S extends "boolean"
      ? boolean
      : S extends readonly (infer V)[]
        ? V
        : never;

// One `{ type, ...fields }` object type per entry of a spec table.
type Message<Specs extends MessageSpecs> = {
  [T in keyof Specs & string]: { readonly type: T } & { readonly [F in keyof Specs[T]]: FieldValue<Specs[T][F]> };
}[keyof Specs & string];

const COMMANDS = {
  // Start recording a meeting into a new <yyyy-MM-dd-HHmm> folder under `root`.
  "meeting.start": { root: "string" },
  // Stop the meeting; the engine writes meta.json and meeting.m4a, then reports meeting.stopped.
  "meeting.stop": {},
  // Transcribe a finished session folder, one at a time.
  "transcription.start": { dir: "string" },
  // Download the speech model if it is missing, with model.progress events.
  "model.prepare": {},
} as const satisfies MessageSpecs;

const EVENTS = {
  // The engine is listening; `modelDownloaded` says whether Parakeet is cached.
  ready: { modelDownloaded: "boolean" },
  "meeting.started": { dir: "string", startedAt: "string" },
  // Peak levels (0–1), about ten times a second while recording.
  "meeting.level": { mic: "number", system: "number" },
  // A track lost capture mid-meeting; the recording goes on.
  "meeting.warning": { message: "string" },
  "meeting.stopped": { dir: "string", status: TRACK_STATUSES },
  // The meeting could not start (a missing permission, for one).
  "meeting.failed": { message: "string" },
  "model.progress": { phase: MODEL_PHASES, fraction: "number" },
  "model.ready": {},
  "model.failed": { message: "string" },
  "transcription.started": { dir: "string" },
  "transcription.done": { dir: "string" },
  "transcription.failed": { dir: "string", message: "string" },
  // A command line the engine could not act on.
  error: { message: "string" },
} as const satisfies MessageSpecs;

export type EngineCommand = Message<typeof COMMANDS>;
export type EngineEvent = Message<typeof EVENTS>;

export const ENGINE_COMMAND_TYPES = Object.keys(COMMANDS) as ReadonlyArray<EngineCommand["type"]>;
export const ENGINE_EVENT_TYPES = Object.keys(EVENTS) as ReadonlyArray<EngineEvent["type"]>;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function fieldMatches(spec: FieldSpec, value: unknown): boolean {
  return typeof spec === "string" ? typeof value === spec : typeof value === "string" && spec.includes(value);
}

function isMessage<Specs extends MessageSpecs>(specs: Specs, value: unknown): value is Message<Specs> {
  if (!isRecord(value) || typeof value.type !== "string" || !Object.hasOwn(specs, value.type)) return false;
  const fields: Record<string, FieldSpec> = specs[value.type] ?? {};
  return Object.entries(fields).every(([name, spec]) => fieldMatches(spec, value[name]));
}

export function isEngineCommand(value: unknown): value is EngineCommand {
  return isMessage(COMMANDS, value);
}

// One stdout line from the engine, or null when it isn't a known event.
export function parseEngineEvent(line: string): EngineEvent | null {
  try {
    const value: unknown = JSON.parse(line);
    return isMessage(EVENTS, value) ? value : null;
  } catch {
    return null;
  }
}
