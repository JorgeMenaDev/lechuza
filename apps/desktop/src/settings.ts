import * as fs from "node:fs/promises";

import { HOTKEYS, type Hotkey, type Settings, type Theme } from "@lechuza/contracts";

// Settings live in settings.json in the app's data folder. A missing or
// malformed file, or a field from an older version, falls back to the default.
const DEFAULTS: Settings = { theme: "system", hotkey: "fn", sounds: true };
const THEMES: ReadonlyArray<Theme> = ["system", "light", "dark"];

export function isTheme(value: unknown): value is Theme {
  return THEMES.some((theme) => theme === value);
}

export function isHotkey(value: unknown): value is Hotkey {
  return HOTKEYS.some((hotkey) => hotkey === value);
}

export function parseSettings(value: unknown): Settings {
  const saved: Partial<Record<keyof Settings, unknown>> = typeof value === "object" && value !== null ? value : {};
  return {
    theme: isTheme(saved.theme) ? saved.theme : DEFAULTS.theme,
    hotkey: isHotkey(saved.hotkey) ? saved.hotkey : DEFAULTS.hotkey,
    sounds: typeof saved.sounds === "boolean" ? saved.sounds : DEFAULTS.sounds,
  };
}

export async function loadSettings(file: string): Promise<Settings> {
  try {
    const value: unknown = JSON.parse(await fs.readFile(file, "utf8"));
    return parseSettings(value);
  } catch {
    return DEFAULTS;
  }
}

// The save in progress. Saves run one at a time in call order, so two quick
// changes never share the temp file and the later one wins.
let saving: Promise<void> = Promise.resolve();

// Writes through a temp file, so a failed write leaves the old settings whole.
export function saveSettings(file: string, settings: Settings): Promise<void> {
  const save = saving.then(async () => {
    await fs.writeFile(`${file}.part`, `${JSON.stringify(settings, null, 2)}\n`);
    await fs.rename(`${file}.part`, file);
  });
  saving = save.catch(() => {});
  return save;
}
