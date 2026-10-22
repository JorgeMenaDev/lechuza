import * as fs from "node:fs/promises";
import * as path from "node:path";

import { MEDIA_SCHEME, type Meeting, type MeetingState, type TranscriptLine } from "@lechuza/contracts";

// Meetings live as plain folders under the meetings root, one per meeting,
// named <yyyy-MM-dd-HHmm> (with -2, -3… on a clash). The engine writes:
//   mic.caf, system.caf    the two tracks (mic-002.caf… after a capture restart)
//   meeting.m4a            the mix the app plays
//   meta.json              times and tracks; the app adds `title` on rename
//   transcript.json / .md  the me / them transcript
//   transcript-error.txt   why the last transcription failed
//   transcribe.log         the engine's notes on transcription
const FOLDER_NAME = /^(\d{4})-(\d{2})-(\d{2})-(\d{2})(\d{2})(?:-\d+)?$/;
export const MIX_FILE = "meeting.m4a";
const ERROR_FILE = "transcript-error.txt";

// What main knows about meetings that disk doesn't say yet.
export interface LiveMeetings {
  readonly recording: { readonly id: string; readonly startedAt: number } | null;
  // Being transcribed or waiting for it.
  readonly transcribing: ReadonlySet<string>;
}

interface SessionMeta {
  readonly started: string;
  readonly durationSeconds: number;
  readonly title: string | null;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

async function readJson(file: string): Promise<unknown> {
  try {
    const value: unknown = JSON.parse(await fs.readFile(file, "utf8"));
    return value;
  } catch {
    return null;
  }
}

// The fields of meta.json the app uses, or null when it's missing or malformed.
function parseMeta(value: unknown): SessionMeta | null {
  if (!isRecord(value) || typeof value.started !== "string" || typeof value.duration_seconds !== "number") return null;
  return {
    started: value.started,
    durationSeconds: value.duration_seconds,
    title: typeof value.title === "string" ? value.title : null,
  };
}

function parseTranscript(value: unknown): TranscriptLine[] {
  if (!isRecord(value) || !Array.isArray(value.segments)) return [];
  return value.segments.flatMap((segment: unknown): TranscriptLine[] => {
    if (!isRecord(segment)) return [];
    const { speaker, start_ms, end_ms, text } = segment;
    if ((speaker !== "me" && speaker !== "them") || typeof start_ms !== "number") return [];
    if (typeof end_ms !== "number" || typeof text !== "string") return [];
    return [{ speaker, startMs: start_ms, endMs: end_ms, text }];
  });
}

// "Meeting – 22 Oct 2026, 14:05" in `locale` (the runtime's default when undefined).
function defaultTitle(date: Date, locale: string | undefined): string {
  const stamp = date.toLocaleString(locale, {
    day: "numeric",
    month: "short",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
  return `Meeting – ${stamp}`;
}

async function exists(file: string): Promise<boolean> {
  return fs.stat(file).then(
    () => true,
    () => false,
  );
}

export class MeetingLibrary {
  // `locale` formats default titles; pass the app's, so they match the page.
  constructor(
    readonly root: string,
    private readonly locale?: string,
  ) {}

  // A meeting's folder, or null for an id that would leave the root.
  dir(id: string): string | null {
    const resolved = path.resolve(this.root, id);
    return path.dirname(resolved) === path.resolve(this.root) && FOLDER_NAME.test(id) ? resolved : null;
  }

  mixFile(id: string): string | null {
    const dir = this.dir(id);
    return dir && path.join(dir, MIX_FILE);
  }

  // Newest first. State comes from the files, overridden by what main knows
  // is live: recording > transcribing > ready > failed.
  async list(live: LiveMeetings): Promise<Meeting[]> {
    const names = await fs.readdir(this.root).catch(() => []);
    const meetings = await Promise.all(names.filter((name) => FOLDER_NAME.test(name)).map((id) => this.load(id, live)));
    return meetings.sort((a, b) => Date.parse(b.startedAt) - Date.parse(a.startedAt));
  }

  async transcript(id: string): Promise<TranscriptLine[]> {
    const dir = this.dir(id);
    return dir ? parseTranscript(await readJson(path.join(dir, "transcript.json"))) : [];
  }

  // Sets `title` in meta.json, keeping everything the engine wrote. Writes
  // through a temp file, so a failed write leaves the old metadata whole.
  async rename(id: string, title: string): Promise<void> {
    const dir = this.dir(id);
    const raw = dir && (await readJson(path.join(dir, "meta.json")));
    if (!dir || !isRecord(raw) || title.trim() === "") return;
    const temp = path.join(dir, ".meta.json.part");
    await fs.writeFile(temp, `${JSON.stringify({ ...raw, title: title.trim() }, null, 2)}\n`);
    await fs.rename(temp, path.join(dir, "meta.json"));
  }

  // Records why a transcription failed when the engine couldn't (it died).
  async recordFailure(id: string, message: string): Promise<void> {
    const dir = this.dir(id);
    if (dir) await fs.writeFile(path.join(dir, ERROR_FILE), `${message}\n`);
  }

  // Finished meetings with neither a transcript nor a failure: transcription
  // was cut short, so it runs again at launch. Oldest first.
  async untranscribed(): Promise<string[]> {
    const names = await fs.readdir(this.root).catch(() => []);
    const pending = await Promise.all(
      names.filter((name) => FOLDER_NAME.test(name)).map(async (id) => {
        const dir = path.join(this.root, id);
        const [meta, transcript, error] = await Promise.all(
          ["meta.json", "transcript.json", ERROR_FILE].map((file) => exists(path.join(dir, file))),
        );
        return meta && !transcript && !error ? [id] : [];
      }),
    );
    return pending.flat().sort();
  }

  private async load(id: string, live: LiveMeetings): Promise<Meeting> {
    const dir = path.join(this.root, id);
    const [meta, hasTranscript, error, mix] = await Promise.all([
      readJson(path.join(dir, "meta.json")).then(parseMeta),
      exists(path.join(dir, "transcript.json")),
      fs.readFile(path.join(dir, ERROR_FILE), "utf8").then(
        (text) => text.trim(),
        () => null,
      ),
      fs.stat(path.join(dir, MIX_FILE)).catch(() => null),
    ]);
    const recording = live.recording?.id === id ? live.recording : null;
    const startedAt = recording ? new Date(recording.startedAt) : meta ? new Date(meta.started) : folderDate(id);

    const state: MeetingState = recording
      ? "recording"
      : live.transcribing.has(id)
        ? "transcribing"
        : hasTranscript
          ? "ready"
          : error !== null || !meta
            ? "failed"
            : "transcribing";
    return {
      id,
      title: meta?.title ?? defaultTitle(startedAt, this.locale),
      startedAt: meta && !recording ? meta.started : startedAt.toISOString(),
      durationMs: meta && !recording ? meta.durationSeconds * 1000 : 0,
      state,
      error: state !== "failed" ? null : (error ?? "The recording stopped before it was saved."),
      // The mtime query busts the renderer's cache when the mix is rewritten.
      audioUrl: mix ? `${MEDIA_SCHEME}://meeting/${encodeURIComponent(id)}?v=${mix.mtime.getTime()}` : null,
    };
  }
}

// The local time a folder's name records, for meetings without meta.json.
function folderDate(id: string): Date {
  const [, year, month, day, hour, minute] = (FOLDER_NAME.exec(id) ?? []).map(Number);
  return new Date(year ?? 0, (month ?? 1) - 1, day ?? 1, hour ?? 0, minute ?? 0);
}
