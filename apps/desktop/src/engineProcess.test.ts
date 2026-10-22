import { describe, expect, test } from "bun:test";
import { spawn } from "node:child_process";

import { killOnStdinError } from "./engineProcess.ts";

describe("EngineProcess", () => {
  // Bun reports EPIPE only for writes it can't finish at once; Node, which
  // Electron runs on, reports it for any write. So raise it directly.
  test("a broken stdin pipe kills the engine instead of crashing main", async () => {
    const child = spawn("sleep", ["30"], { stdio: ["pipe", "ignore", "ignore"] });
    const closed = new Promise((resolve) => child.once("close", resolve));
    killOnStdinError(child);

    child.stdin?.emit("error", Object.assign(new Error("write EPIPE"), { code: "EPIPE" }));

    await closed;
    expect(child.killed).toBe(true);
  });
});
