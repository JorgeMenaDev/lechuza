import * as path from "node:path";

import { app, BrowserWindow, nativeTheme, screen } from "electron";

import type { Surface } from "@lechuza/contracts";

// Every window loads the same React bundle; the hash picks the screen.
const DEV_URL = process.env.LECHUZA_DEV_URL;
// Resolved from the app root: the bundler bakes `__dirname` in at build time.
const appFile = (relative: string) => path.join(app.getAppPath(), relative);

function load(win: BrowserWindow, surface: Surface): void {
  if (DEV_URL) void win.loadURL(`${DEV_URL}#/${surface}`);
  else void win.loadFile(appFile("dist-renderer/index.html"), { hash: `/${surface}` });
}

// The chrome and sidebar colour (--window in index.css), shown before the page paints.
export function windowBackground(): string {
  return nativeTheme.shouldUseDarkColors ? "#202020" : "#f5f4f0";
}

// 1350×850 when the screen has room, never closer than 10 pt to the work area's edges.
export function createMainWindow(): BrowserWindow {
  const area = screen.getPrimaryDisplay().workAreaSize;
  const width = Math.min(1350, area.width - 20);
  const height = Math.min(850, area.height - 20);
  const win = new BrowserWindow({
    width,
    height,
    minWidth: Math.min(1140, width),
    minHeight: Math.min(750, height),
    show: false,
    title: "Lechuza",
    titleBarStyle: "hidden",
    trafficLightPosition: { x: 16, y: 19 },
    backgroundColor: windowBackground(),
    webPreferences: { preload: appFile("dist-electron/preload.cjs"), contextIsolation: true, sandbox: true },
  });
  win.once("ready-to-show", () => win.show());
  load(win, "main");
  return win;
}
