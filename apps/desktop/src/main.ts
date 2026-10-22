import * as path from "node:path";

import {
  app,
  BrowserWindow,
  clipboard,
  ipcMain,
  Menu,
  protocol,
  shell,
  Tray,
  type MenuItemConstructorOptions,
} from "electron";

import { IPC, MEDIA_SCHEME, formatClock, formatTranscript, type AppState } from "@lechuza/contracts";

import { EngineProcess } from "./engineProcess.ts";
import { MeetingLibrary } from "./library.ts";
import { handleMediaRequest } from "./mediaProtocol.ts";
import { Meetings } from "./meetings.ts";
import { createTrayIcon } from "./trayIcon.ts";
import { createMainWindow } from "./windows.ts";

protocol.registerSchemesAsPrivileged([
  { scheme: MEDIA_SCHEME, privileges: { standard: true, secure: true, supportFetchAPI: true, stream: true } },
]);

let mainWindow: BrowserWindow | null = null;
let tray: Tray | null = null;
let trayTimer: NodeJS.Timeout | null = null;
let quitting = false;

function showMainWindow(): void {
  if (!mainWindow || mainWindow.isDestroyed()) {
    mainWindow = createMainWindow();
    mainWindow.on("closed", () => (mainWindow = null));
  } else {
    mainWindow.show();
  }
  mainWindow.focus();
}

function broadcast(channel: string, value: unknown): void {
  for (const win of BrowserWindow.getAllWindows()) win.webContents.send(channel, value);
}

// While recording, the menu bar shows the elapsed time next to the owl.
function syncTray(state: AppState): void {
  if (trayTimer) clearInterval(trayTimer);
  trayTimer = null;
  const recording = state.recording;
  const render = () => tray?.setTitle(recording ? ` ${formatClock(Date.now() - recording.startedAt)}` : "");
  render();
  if (recording) trayTimer = setInterval(render, 500);
}

function trayMenu(meetings: Meetings): Menu {
  const recording = meetings.recording;
  const meetingItem: MenuItemConstructorOptions =
    meetings.phase === "recording" && recording
      ? { label: `Stop meeting (${formatClock(Date.now() - recording.startedAt)})`, click: () => meetings.stop() }
      : meetings.phase === "starting"
        ? { label: "Starting meeting…", enabled: false }
        : meetings.phase === "stopping"
          ? { label: "Saving meeting…", enabled: false }
          : { label: "Start meeting", click: () => meetings.start() };
  return Menu.buildFromTemplate([
    meetingItem,
    { type: "separator" },
    { label: "Open Lechuza", click: showMainWindow },
    { type: "separator" },
    { role: "quit", label: "Quit Lechuza" },
  ]);
}

function registerIpc(meetings: Meetings, library: MeetingLibrary): void {
  // Renderer arguments arrive untyped; anything but a string becomes "".
  const text = (value: unknown) => (typeof value === "string" ? value : "");

  ipcMain.handle(IPC.getState, () => meetings.state());
  ipcMain.handle(IPC.startMeeting, () => meetings.start());
  ipcMain.handle(IPC.stopMeeting, () => meetings.stop());
  ipcMain.handle(IPC.getTranscript, (_event, id: unknown) => library.transcript(text(id)));
  ipcMain.handle(IPC.copyTranscript, async (_event, id: unknown) => {
    clipboard.writeText(formatTranscript(await library.transcript(text(id))));
  });
  ipcMain.handle(IPC.renameMeeting, async (_event, id: unknown, title: unknown) => {
    await library.rename(text(id), text(title));
    meetings.publish();
  });
  // Never under a meeting that's still being recorded or transcribed.
  ipcMain.handle(IPC.trashMeeting, async (_event, id: unknown) => {
    const meeting = (await meetings.state()).meetings.find((candidate) => candidate.id === text(id));
    const dir = library.dir(text(id));
    if (!meeting || !dir || meeting.state === "recording" || meeting.state === "transcribing") return;
    await shell.trashItem(dir);
    meetings.publish();
  });
  ipcMain.handle(IPC.revealMeeting, (_event, id: unknown) => {
    const dir = library.dir(text(id));
    if (dir) shell.showItemInFolder(dir);
  });
  ipcMain.handle(IPC.retryTranscription, (_event, id: unknown) => meetings.retry(text(id)));
  ipcMain.handle(IPC.dismissNotice, () => meetings.dismissNotice());
}

void app.whenReady().then(() => {
  // LECHUZA_MEETINGS_DIR points the app at another folder, for demos and screenshots.
  const library = new MeetingLibrary(
    process.env.LECHUZA_MEETINGS_DIR ?? path.join(app.getPath("documents"), "Lechuza", "Meetings"),
    app.getLocale(),
  );
  // Packaged, the engine sits in Contents/Resources; `bun run dev` points at the Swift build.
  const engine = new EngineProcess(process.env.LECHUZA_ENGINE ?? path.join(process.resourcesPath, "lechuza-engine"), {
    onEvent: (event) => void meetings.handle(event),
    onExit: (ran) => {
      void meetings.engineExited();
      // An engine that never got going (a missing binary) would only fail again.
      if (ran && !quitting) setTimeout(() => engine.start(), 1000);
    },
  });
  const meetings = new Meetings(library, engine, {
    onState: (state) => {
      broadcast(IPC.state, state);
      syncTray(state);
    },
    onLevels: (levels) => broadcast(IPC.levels, levels),
  });

  protocol.handle(MEDIA_SCHEME, (request) => handleMediaRequest(library, request));
  registerIpc(meetings, library);
  engine.start();

  tray = new Tray(createTrayIcon());
  tray.setToolTip("Lechuza");
  tray.on("click", () => tray?.popUpContextMenu(trayMenu(meetings)));
  tray.on("right-click", () => tray?.popUpContextMenu(trayMenu(meetings)));
  meetings.publish();

  // Closing the engine's stdin makes it save a meeting in progress before it exits.
  app.on("before-quit", (event) => {
    if (quitting) return;
    quitting = true;
    event.preventDefault();
    void engine.stop().then(() => app.quit());
  });
  app.on("activate", showMainWindow);
  showMainWindow();
});

// Lechuza lives in the menu bar; closing the window keeps it running.
app.on("window-all-closed", () => {});
