import { useEffect, useState, useSyncExternalStore } from "react";

import type {
  AppState,
  Dictation,
  DictationState,
  LechuzaBridge,
  Levels,
  Meeting,
  TranscriptLine,
} from "@lechuza/contracts";

declare global {
  interface Window {
    readonly lechuza: LechuzaBridge;
  }
}

export const lechuza = window.lechuza;

// The state main owns and broadcasts; null until the first read lands.
export function useAppState(): AppState | null {
  const [state, setState] = useState<AppState | null>(null);
  useEffect(() => {
    let active = true;
    void lechuza.getState().then((initial) => active && setState(initial));
    const unsubscribe = lechuza.onState(setState);
    return () => {
      active = false;
      unsubscribe();
    };
  }, []);
  return state;
}

// Live microphone and system audio levels while a meeting records.
export function useLevels(): Levels {
  const [levels, setLevels] = useState<Levels>({ mic: 0, system: 0 });
  useEffect(() => lechuza.onLevels(setLevels), []);
  return levels;
}

// Re-renders every `intervalMs` while `enabled`, for ticking clocks.
export function useNow(enabled: boolean, intervalMs = 500): number {
  const [now, setNow] = useState(Date.now);
  useEffect(() => {
    if (!enabled) return;
    setNow(Date.now());
    const timer = setInterval(() => setNow(Date.now()), intervalMs);
    return () => clearInterval(timer);
  }, [enabled, intervalMs]);
  return now;
}

// The meeting's transcript once it's ready, or the lines that worked when
// transcription partly failed; empty before.
export function useTranscript(meeting: Meeting): ReadonlyArray<TranscriptLine> {
  const [lines, setLines] = useState<ReadonlyArray<TranscriptLine>>([]);
  const ready = meeting.state === "ready" || meeting.state === "failed";
  useEffect(() => {
    if (!ready) {
      setLines([]);
      return;
    }
    let active = true;
    void lechuza.getTranscript(meeting.id).then((loaded) => active && setLines(loaded));
    return () => {
      active = false;
    };
  }, [meeting.id, ready]);
  return lines;
}

// The newest `count` dictations: the ones DictationState carries, or more
// read through main, again whenever a new dictation lands.
export function useDictations(dictation: DictationState, count: number): ReadonlyArray<Dictation> {
  const [read, setRead] = useState<ReadonlyArray<Dictation> | null>(null);
  const more = count > dictation.recent.length && dictation.stats.count > dictation.recent.length;
  const newest = dictation.recent[0]?.id;
  useEffect(() => {
    if (!more) return;
    let active = true;
    void lechuza.getDictations(count).then((loaded) => active && setRead(loaded));
    return () => {
      active = false;
    };
  }, [more, count, newest]);
  return more && read ? read : dictation.recent;
}

const darkQuery = window.matchMedia("(prefers-color-scheme: dark)");

// Whether the window is dark now: the theme setting, or the Mac's appearance under "system".
export function useDarkMode(): boolean {
  return useSyncExternalStore(
    (onChange) => {
      darkQuery.addEventListener("change", onChange);
      return () => darkQuery.removeEventListener("change", onChange);
    },
    () => darkQuery.matches,
  );
}
