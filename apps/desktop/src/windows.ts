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

// The Flow bar's window: room for the pill and a tooltip above it. Clicks
// pass through all of it except the pill (see setFlowBarHover in main.ts).
const FLOW_BAR = { width: 600, height: 100 };

// The Flow bar: a transparent panel along the bottom centre of the screen,
// over every Space and full-screen app. A panel never activates Lechuza, so
// the app you are typing in keeps the focus.
export function createFlowBarWindow(): BrowserWindow {
  const win = new BrowserWindow({
    ...FLOW_BAR,
    type: "panel",
    frame: false,
    transparent: true,
    backgroundColor: "#00000000",
    hasShadow: false,
    resizable: false,
    movable: false,
    minimizable: false,
    maximizable: false,
    fullscreenable: false,
    focusable: false,
    skipTaskbar: true,
    hiddenInMissionControl: true,
    show: false,
    webPreferences: {
      preload: appFile("dist-electron/preload.cjs"),
      contextIsolation: true,
      sandbox: true,
      // The waveform animates while another app is in front.
      backgroundThrottling: false,
    },
  });
  win.setAlwaysOnTop(true, "screen-saver");
  win.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true, skipTransformProcessType: true });
  win.setIgnoreMouseEvents(true, { forward: true });
  placeFlowBar(win);
  win.once("ready-to-show", () => win.showInactive());
  load(win, "flow-bar");
  return win;
}

// Bottom centre of the work area (above the Dock) of the screen with the pointer.
export function placeFlowBar(win: BrowserWindow): void {
  const area = screen.getDisplayNearestPoint(screen.getCursorScreenPoint()).workArea;
  win.setBounds({
    x: Math.round(area.x + (area.width - FLOW_BAR.width) / 2),
    y: area.y + area.height - FLOW_BAR.height,
    ...FLOW_BAR,
  });
}
