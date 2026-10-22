import { CircleAlert } from "lucide-react";
import { useEffect, useRef, useState } from "react";

import type { DictationPhase } from "@lechuza/contracts";

import { lechuza, useAppState } from "../bridge";
import { flowBarView, meter } from "../lib/flowBar";
import { playSound } from "../lib/sounds";
import { HOTKEY_NAMES } from "../ui";

// The Flow bar, alone in a transparent window at the bottom of the screen:
// a small pill at rest, a live waveform while you dictate, a shimmer while
// Parakeet transcribes, a red edge when something failed. Clicks fall
// through the window except on the pill, which only takes them while hovered.

export function FlowBar() {
  const state = useAppState();
  const [hover, setHover] = useState(false);
  usePhaseSounds(state?.dictation.phase ?? "idle", state?.settings.sounds ?? false);
  if (!state) return null;

  const view = flowBarView(state.dictation, hover);
  const key = HOTKEY_NAMES[state.settings.hotkey].key;
  const tooltip =
    view === "hover" ? `Click or hold ${key} to dictate` : view === "error" ? state.dictation.error : null;
  const hovering = (on: boolean) => {
    setHover(on);
    void lechuza.setFlowBarHover(on);
  };

  return (
    <div className="flow-bar">
      {tooltip && <p className="flow-tooltip">{tooltip}</p>}
      <div className="flow-hit" onMouseEnter={() => hovering(true)} onMouseLeave={() => hovering(false)}>
        <div className="flow-pill" data-view={view} onClick={() => view === "hover" && void lechuza.startDictation()}>
          {(view === "hover" || view === "listening" || view === "handsFree") && <Waveform live={view !== "hover"} />}
          {view === "handsFree" && (
            <button className="flow-stop" title="Stop and paste" onClick={() => void lechuza.stopDictation()} />
          )}
          {view === "transcribing" && <Processing />}
          {view === "error" && <CircleAlert className="flow-error-icon" />}
        </div>
      </div>
    </div>
  );
}

// Ten bars that follow the microphone, each swaying on a one-second loop.
// Levels go straight to a CSS variable, smoothed every frame, outside React.
function Waveform({ live }: { live: boolean }) {
  const wave = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!live) return;
    let floorDb = 0;
    let target = 0;
    let shown = 0;
    let frame = 0;
    const unsubscribe = lechuza.onDictationLevel((rms) => {
      const reading = meter(floorDb, rms);
      floorDb = reading.floorDb;
      target = reading.level;
    });
    const tick = () => {
      shown += (target - shown) * 0.15;
      wave.current?.style.setProperty("--level", shown.toFixed(3));
      frame = requestAnimationFrame(tick);
    };
    frame = requestAnimationFrame(tick);
    return () => {
      unsubscribe();
      cancelAnimationFrame(frame);
    };
  }, [live]);
  return (
    <div ref={wave} className="flow-wave" data-live={live}>
      {Array.from({ length: 10 }, (_, bar) => (
        <span key={bar} />
      ))}
    </div>
  );
}

function Processing() {
  return (
    <div className="flow-processing">
      {Array.from({ length: 6 }, (_, dot) => (
        <span key={dot} />
      ))}
    </div>
  );
}

const capturing = (phase: DictationPhase) => phase === "listening" || phase === "handsFree";

// The start sound when the microphone opens, the stop sound when it closes
// to transcribe. A cancelled dictation ends quietly.
function usePhaseSounds(phase: DictationPhase, on: boolean) {
  const previous = useRef(phase);
  useEffect(() => {
    const was = previous.current;
    previous.current = phase;
    if (!on) return;
    if (capturing(phase) && !capturing(was)) playSound("start");
    if (phase === "transcribing" && capturing(was)) playSound("stop");
  }, [phase, on]);
}
