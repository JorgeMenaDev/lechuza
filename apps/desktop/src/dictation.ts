import { randomUUID } from "node:crypto";

import type { DictationEvent, DictationPhase, DictationState, Hotkey } from "@lechuza/contracts";

import type { DictationHistory } from "./dictationHistory.ts";
import type { EngineLink } from "./meetings.ts";

export interface DictationsListener {
  onState(): void;
  onLevel(level: number): void;
}

// What macOS says about dictation: whether Lechuza has Accessibility, and
// whether the "Press 🌐 key to" setting is "Do Nothing".
export interface MacFacts {
  readonly accessibility: boolean;
  readonly globeDoesNothing: boolean;
}

// How long a failure stays on the Flow bar.
const ERROR_MS = 4_000;

// Dictation's side of AppState. The engine owns the hotkey, the microphone
// and the paste; this mirrors its phase, keeps the history, and holds the
// latest failure for the Flow bar.
export class Dictations {
  #phase: DictationPhase = "idle";
  private error: string | null = null;
  private errorTimer: ReturnType<typeof setTimeout> | undefined;
  private mac: MacFacts = { accessibility: false, globeDoesNothing: true };

  constructor(
    readonly history: DictationHistory,
    private readonly engine: EngineLink,
    private hotkey: Hotkey,
    private readonly listener: DictationsListener,
  ) {}

  state(): DictationState {
    return {
      phase: this.#phase,
      error: this.error,
      accessibility: this.mac.accessibility,
      fnConflict: this.hotkey === "fn" && !this.mac.globeDoesNothing,
      recent: this.history.recent(),
      stats: this.history.stats(),
    };
  }

  // Has the engine listen for `hotkey`. Also sent whenever the engine starts.
  configure(hotkey: Hotkey = this.hotkey): void {
    this.hotkey = hotkey;
    this.engine.send({ type: "dictation.configure", hotkey });
    this.listener.onState();
  }

  start(): void {
    this.engine.send({ type: "dictation.start" });
  }

  stop(): void {
    this.engine.send({ type: "dictation.stop" });
  }

  // Fresh facts from macOS. The engine can only listen for the hotkey once
  // Accessibility is granted, so it is configured again then.
  setMac(facts: Partial<MacFacts>): void {
    const before = this.mac;
    this.mac = { ...before, ...facts };
    if (this.mac.accessibility && !before.accessibility) this.configure();
    else if (this.mac.accessibility !== before.accessibility || this.mac.globeDoesNothing !== before.globeDoesNothing) {
      this.listener.onState();
    }
  }

  async handle(event: DictationEvent): Promise<void> {
    switch (event.type) {
      case "dictation.state":
        this.#phase = event.phase;
        if (event.phase === "listening" || event.phase === "handsFree") this.showError(null);
        break;
      case "dictation.level":
        this.listener.onLevel(event.level);
        return;
      case "dictation.done":
        await this.history.add({
          id: randomUUID(),
          text: event.text,
          startedAt: event.startedAt,
          durationMs: event.durationMs,
        });
        break;
      case "dictation.failed":
        this.showError(event.message);
        break;
    }
    this.listener.onState();
  }

  engineExited(): void {
    this.#phase = "idle";
    this.listener.onState();
  }

  private showError(message: string | null): void {
    clearTimeout(this.errorTimer);
    this.error = message;
    if (message) {
      this.errorTimer = setTimeout(() => {
        this.error = null;
        this.listener.onState();
      }, ERROR_MS);
    }
  }
}
