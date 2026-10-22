import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import * as fs from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";

import { loadSettings, parseSettings, saveSettings } from "./settings.ts";

let dir: string;

beforeEach(async () => {
  dir = await fs.mkdtemp(path.join(os.tmpdir(), "lechuza-settings-"));
});

afterEach(async () => {
  await fs.rm(dir, { recursive: true, force: true });
});

describe("settings", () => {
  test("keeps a known theme and falls back to the system one otherwise", () => {
    expect(parseSettings({ theme: "dark" })).toEqual({ theme: "dark" });
    expect(parseSettings({ theme: "sepia" })).toEqual({ theme: "system" });
    expect(parseSettings(null)).toEqual({ theme: "system" });
  });

  test("saves and loads, with defaults before the first save", async () => {
    const file = path.join(dir, "settings.json");
    expect(await loadSettings(file)).toEqual({ theme: "system" });
    await saveSettings(file, { theme: "light" });
    expect(await loadSettings(file)).toEqual({ theme: "light" });
  });
});
