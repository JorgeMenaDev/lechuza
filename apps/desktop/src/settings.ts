import * as fs from "node:fs/promises";

import type { Settings, Theme } from "@lechuza/contracts";

// Settings live in settings.json in the app's data folder. A missing or
// malformed file, or a field from an older version, falls back to the default.
const DEFAULTS: Settings = { theme: "system" };
const THEMES: ReadonlyArray<Theme> = ["system", "light", "dark"];

export function isTheme(value: unknown): value is Theme {
  return THEMES.some((theme) => theme === value);
}

export function parseSettings(value: unknown): Settings {
  const theme = typeof value === "object" && value !== null && "theme" in value ? value.theme : undefined;
  return { theme: isTheme(theme) ? theme : DEFAULTS.theme };
}

export async function loadSettings(file: string): Promise<Settings> {
  try {
    const value: unknown = JSON.parse(await fs.readFile(file, "utf8"));
    return parseSettings(value);
  } catch {
    return DEFAULTS;
  }
}

// Writes through a temp file, so a failed write leaves the old settings whole.
export async function saveSettings(file: string, settings: Settings): Promise<void> {
  await fs.writeFile(`${file}.part`, `${JSON.stringify(settings, null, 2)}\n`);
  await fs.rename(`${file}.part`, file);
}
