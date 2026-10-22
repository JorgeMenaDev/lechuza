import * as path from "node:path";

import type { EngineCommand, EngineEvent, Levels, MeetingsState, ModelStatus, RecorderPhase } from "@lechuza/contracts";

import type { MeetingLibrary } from "./library.ts";

export interface EngineLink {
  send(command: EngineCommand): void;
}

export interface MeetingsListener {
  onState(state: MeetingsState): void;
  onLevels(levels: Levels): void;
}

// The meeting lifecycle and the single source of meeting state. Intents come
// from the tray and the renderer; facts come from the engine's events. Every
// change is broadcast as a whole MeetingsState, which main completes into the
// AppState windows get. Transcription runs one meeting at a time, in the order
// meetings were queued.
export class Meetings {
  #phase: RecorderPhase = "idle";
  #recording: { id: string; startedAt: number } | null = null;
  private model: ModelStatus = { state: "unknown" };
  private notice: string | null = null;
  private queue: string[] = [];
  private current: string | null = null;
  // Broadcasts run in order, so a slow disk read never sends a stale state last.
  private publishing = Promise.resolve();

  constructor(
    readonly library: MeetingLibrary,
    private readonly engine: EngineLink,
    private readonly listener: MeetingsListener,
  ) {}

  get phase(): RecorderPhase {
    return this.#phase;
  }

  // The meeting being recorded, with its start in epoch milliseconds.
  get recording(): { readonly id: string; readonly startedAt: number } | null {
    return this.#recording;
  }

  async state(): Promise<MeetingsState> {
    const transcribing = new Set([...this.queue, ...(this.current ? [this.current] : [])]);
    return {
      phase: this.#phase,
      recording: this.#recording,
      model: this.model,
      notice: this.notice,
      meetings: await this.library.list({ recording: this.#recording, transcribing }),
    };
  }

  // Sends the latest state to every window; call after changing files too.
  publish(): void {
    this.publishing = this.publishing.then(async () => this.listener.onState(await this.state()));
  }

  start(): void {
    if (this.#phase !== "idle") return;
    this.#phase = "starting";
    this.notice = null;
    this.engine.send({ type: "meeting.start", root: this.library.root });
    this.publish();
  }

  stop(): void {
    if (this.#phase !== "recording") return;
    this.#phase = "stopping";
    this.engine.send({ type: "meeting.stop" });
    this.publish();
  }

  retry(id: string): void {
    this.enqueue(id);
    this.publish();
  }

  dismissNotice(): void {
    this.notice = null;
    this.publish();
  }

  async handle(event: EngineEvent): Promise<void> {
    switch (event.type) {
      case "ready":
        this.model = event.modelDownloaded ? { state: "ready" } : { state: "missing" };
        for (const id of await this.library.untranscribed()) this.enqueue(id);
        break;
      case "meeting.started":
        this.#phase = "recording";
        this.#recording = { id: path.basename(event.dir), startedAt: Date.parse(event.startedAt) };
        // Fetch the model during the meeting, not after it.
        if (this.model.state !== "ready") this.engine.send({ type: "model.prepare" });
        break;
      case "meeting.level":
        this.listener.onLevels({ mic: event.mic, system: event.system });
        return;
      case "meeting.warning":
        this.notice = event.message;
        break;
      case "meeting.stopped":
        this.#phase = "idle";
        this.#recording = null;
        this.enqueue(path.basename(event.dir));
        break;
      case "meeting.failed":
        if (this.#phase === "starting") this.#phase = "idle";
        this.notice = event.message;
        break;
      case "model.progress":
        this.model = { state: "downloading", phase: event.phase, fraction: event.fraction };
        break;
      case "model.ready":
        this.model = { state: "ready" };
        break;
      case "model.failed":
        this.model = { state: "failed", message: event.message };
        break;
      case "transcription.started":
        return;
      case "transcription.done":
      case "transcription.failed":
        this.current = null;
        this.next();
        break;
      case "error":
        console.error(`lechuza-engine: ${event.message}`);
        return;
    }
    this.publish();
  }

  // The engine process ended. A meeting it was recording ends without
  // meta.json and lists as failed; a transcription it was running is marked
  // failed, so a meeting that crashes the engine isn't retried forever.
  async engineExited(): Promise<void> {
    if (this.#phase !== "idle") this.notice = "The recording engine stopped unexpectedly.";
    this.#phase = "idle";
    this.#recording = null;
    if (this.current) await this.library.recordFailure(this.current, "The engine stopped while transcribing.");
    this.current = null;
    this.queue = [];
    this.model = { state: "unknown" };
    this.publish();
  }

  private enqueue(id: string): void {
    if (id === this.current || this.queue.includes(id)) return;
    this.queue.push(id);
    this.next();
  }

  private next(): void {
    if (this.current) return;
    const id = this.queue.shift();
    if (id === undefined) return;
    const dir = this.library.dir(id);
    if (!dir) return this.next();
    this.current = id;
    this.engine.send({ type: "transcription.start", dir });
  }
}
