import * as path from "node:path";

import { app, BrowserWindow, nativeTheme } from "electron";

import type { Surface } from "@lechuza/contracts";

// Every window loads the same React bundle; the hash picks the screen.
const DEV_URL = process.env.LECHUZA_DEV_URL;
// Resolved from the app root: the bundler bakes `__dirname` in at build time.
const appFile = (relative: string) => path.join(app.getAppPath(), relative);

function load(win: BrowserWindow, surface: Surface): void {
  if (DEV_URL) void win.loadURL(`${DEV_URL}#/${surface}`);
  else void win.loadFile(appFile("dist-renderer/index.html"), { hash: `/${surface}` });
}

export function createMainWindow(): BrowserWindow {
  const win = new BrowserWindow({
    width: 1100,
    height: 740,
    minWidth: 760,
    minHeight: 480,
    show: false,
    title: "Lechuza",
    titleBarStyle: "hiddenInset",
    trafficLightPosition: { x: 18, y: 18 },
    backgroundColor: nativeTheme.shouldUseDarkColors ? "#111111" : "#fafafa",
    webPreferences: { preload: appFile("dist-electron/preload.cjs"), contextIsolation: true, sandbox: true },
  });
  win.once("ready-to-show", () => win.show());
  load(win, "meetings");
  return win;
}
