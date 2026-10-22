import { useEffect, useState } from "react";

import type { AppState, LechuzaBridge, Levels } from "@lechuza/contracts";

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
