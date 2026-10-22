import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import * as fs from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";

import type { Settings } from "@lechuza/contracts";

import { loadSettings, parseSettings, saveSettings } from "./settings.ts";

let dir: string;

beforeEach(async () => {
  dir = await fs.mkdtemp(path.join(os.tmpdir(), "lechuza-settings-"));
});

afterEach(async () => {
  await fs.rm(dir, { recursive: true, force: true });
});

const DEFAULTS: Settings = { theme: "system", hotkey: "fn", sounds: true };

describe("settings", () => {
  test("keeps known values and falls back field by field", () => {
    expect(parseSettings({ theme: "dark", hotkey: "rightOption", sounds: false })).toEqual({
      theme: "dark",
      hotkey: "rightOption",
      sounds: false,
    });
    expect(parseSettings({ theme: "sepia", hotkey: "capsLock", sounds: "loud" })).toEqual(DEFAULTS);
    expect(parseSettings(null)).toEqual(DEFAULTS);
  });

  test("reads a file from before dictation with the dictation defaults", () => {
    expect(parseSettings({ theme: "light" })).toEqual({ ...DEFAULTS, theme: "light" });
  });

  test("saves and loads, with defaults before the first save", async () => {
    const file = path.join(dir, "settings.json");
    expect(await loadSettings(file)).toEqual(DEFAULTS);
    await saveSettings(file, { theme: "light", hotkey: "controlOption", sounds: false });
    expect(await loadSettings(file)).toEqual({ theme: "light", hotkey: "controlOption", sounds: false });
  });
});
