import { contextBridge, ipcRenderer, type IpcRendererEvent } from "electron";

import { IPC, type LechuzaBridge } from "@lechuza/contracts";

function subscribe<T>(channel: string, listener: (value: T) => void) {
  const wrapped = (_event: IpcRendererEvent, value: T) => listener(value);
  ipcRenderer.on(channel, wrapped);
  return () => void ipcRenderer.removeListener(channel, wrapped);
}

const bridge: LechuzaBridge = {
  getState: () => ipcRenderer.invoke(IPC.getState),
  onState: (listener) => subscribe(IPC.state, listener),
  onLevels: (listener) => subscribe(IPC.levels, listener),
  onDictationLevel: (listener) => subscribe(IPC.dictationLevel, listener),
  startMeeting: () => ipcRenderer.invoke(IPC.startMeeting),
  stopMeeting: () => ipcRenderer.invoke(IPC.stopMeeting),
  getTranscript: (id) => ipcRenderer.invoke(IPC.getTranscript, id),
  copyTranscript: (id) => ipcRenderer.invoke(IPC.copyTranscript, id),
  renameMeeting: (id, title) => ipcRenderer.invoke(IPC.renameMeeting, id, title),
  trashMeeting: (id) => ipcRenderer.invoke(IPC.trashMeeting, id),
  revealMeeting: (id) => ipcRenderer.invoke(IPC.revealMeeting, id),
  retryTranscription: (id) => ipcRenderer.invoke(IPC.retryTranscription, id),
  dismissNotice: () => ipcRenderer.invoke(IPC.dismissNotice),
  setTheme: (theme) => ipcRenderer.invoke(IPC.setTheme, theme),
  setHotkey: (hotkey) => ipcRenderer.invoke(IPC.setHotkey, hotkey),
  setSounds: (on) => ipcRenderer.invoke(IPC.setSounds, on),
  startDictation: () => ipcRenderer.invoke(IPC.startDictation),
  stopDictation: () => ipcRenderer.invoke(IPC.stopDictation),
  copyDictation: (id) => ipcRenderer.invoke(IPC.copyDictation, id),
  requestAccessibility: () => ipcRenderer.invoke(IPC.requestAccessibility),
  setFlowBarHover: (hover) => ipcRenderer.invoke(IPC.setFlowBarHover, hover),
  revealMeetingsFolder: () => ipcRenderer.invoke(IPC.revealMeetingsFolder),
  openExternal: (page) => ipcRenderer.invoke(IPC.openExternal, page),
};

contextBridge.exposeInMainWorld("lechuza", bridge);
