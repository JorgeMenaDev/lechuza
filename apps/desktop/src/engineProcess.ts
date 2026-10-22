import { spawn, type ChildProcess } from "node:child_process";
import * as readline from "node:readline";

import { parseEngineEvent, type EngineCommand, type EngineEvent } from "@lechuza/contracts";

import type { EngineLink } from "./meetings.ts";

// A write after the engine closed its stdin fails with EPIPE. Unhandled,
// that would crash main; instead the engine counts as failed: killing it
// fires "close", which reports the exit.
export function killOnStdinError(child: ChildProcess): void {
  child.stdin?.on("error", (error) => {
    console.error(`lechuza-engine stdin: ${error.message}`);
    child.kill();
  });
}

export interface EngineHandlers {
  onEvent(event: EngineEvent): void;
  // The engine ended without being asked to; `ran` says whether it ever got going.
  onExit(ran: boolean): void;
}

// Runs lechuza-engine as a child of the app and speaks the JSON-lines
// protocol with it. As a child process it counts as part of Lechuza for
// macOS privacy: the Microphone and System Audio Recording prompts name
// Lechuza and use its Info.plist. The engine's stderr goes to the app's.
export class EngineProcess implements EngineLink {
  private child: ChildProcess | null = null;
  private ran = false;
  // Set by stop(): the app is quitting, so nothing starts the engine again.
  private closed = false;

  constructor(
    private readonly binary: string,
    private readonly handlers: EngineHandlers,
  ) {}

  start(): void {
    if (this.child || this.closed) return;
    const child = spawn(this.binary, [], { stdio: ["pipe", "pipe", "inherit"] });
    this.child = child;
    this.ran = false;
    if (child.stdout) {
      readline.createInterface({ input: child.stdout }).on("line", (line) => {
        const event = parseEngineEvent(line);
        if (!event) return console.error(`lechuza-engine sent an unknown line: ${line}`);
        if (event.type === "ready") this.ran = true;
        this.handlers.onEvent(event);
      });
    }
    child.on("error", (error) => console.error(`lechuza-engine: ${error.message}`));
    killOnStdinError(child);
    child.on("close", () => {
      if (this.child !== child) return;
      this.child = null;
      this.handlers.onExit(this.ran);
    });
  }

  // Starts the engine first if it isn't running; stdin buffers the command.
  send(command: EngineCommand): void {
    this.start();
    this.child?.stdin?.write(`${JSON.stringify(command)}\n`);
  }

  // Closes stdin: the engine saves a meeting in progress, then exits.
  // Resolves once it has, or after `timeoutMs`.
  stop(timeoutMs = 15_000): Promise<void> {
    const child = this.child;
    this.closed = true;
    if (!child) return Promise.resolve();
    this.child = null;
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        child.kill();
        resolve();
      }, timeoutMs);
      child.once("close", () => {
        clearTimeout(timer);
        resolve();
      });
      child.stdin?.end();
    });
  }
}
