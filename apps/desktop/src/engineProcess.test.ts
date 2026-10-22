import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import * as fs from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";

import { EngineProcess } from "./engineProcess.ts";

let dir: string;

// A stand-in engine: a shell script with the given body.
async function fakeEngine(body: string): Promise<string> {
  const file = path.join(dir, "fake-engine");
  await fs.writeFile(file, `#!/bin/sh\n${body}\n`, { mode: 0o755 });
  return file;
}

beforeEach(async () => {
  dir = await fs.mkdtemp(path.join(os.tmpdir(), "lechuza-engine-"));
});

afterEach(async () => {
  await fs.rm(dir, { recursive: true, force: true });
});

describe("EngineProcess", () => {
  test("an engine that closes its stdin counts as an engine failure", async () => {
    // Closes stdin, announces itself, then lingers, so the app's writes hit a broken pipe.
    const binary = await fakeEngine(`exec 0<&-\necho '{"type":"ready","modelDownloaded":true}'\nexec sleep 30`);
    const exited = Promise.withResolvers<boolean>();
    const ready = Promise.withResolvers<void>();
    const engine = new EngineProcess(binary, {
      onEvent: (event) => event.type === "ready" && ready.resolve(),
      onExit: exited.resolve,
    });
    engine.start();
    await ready.promise;
    // Too big to write at once, so the broken pipe surfaces as an EPIPE error.
    engine.send({ type: "transcription.start", dir: "x".repeat(1 << 20) });

    expect(await exited.promise).toBe(true);
  });
});
