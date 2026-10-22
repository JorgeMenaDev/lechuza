import { Check, CircleDot, Copy, Square, type LucideIcon } from "lucide-react";
import { useState, type ReactNode } from "react";

import { formatClock, type AppState, type Meeting, type MeetingState } from "@lechuza/contracts";

import { lechuza, useNow } from "./bridge";

// Pieces shared by the main window's pages. Styles live in index.css under
// the class names.

const STATE_LABELS: Record<MeetingState, string> = {
  recording: "Recording",
  transcribing: "Transcribing",
  ready: "Ready",
  failed: "Failed",
};

// "9:19 pm", in the Mac's locale.
export function formatTime(iso: string): string {
  return new Date(iso).toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });
}

// "Friday 16 Oct", in the Mac's locale.
export function formatDay(iso: string): string {
  return new Date(iso).toLocaleDateString(undefined, { weekday: "long", day: "numeric", month: "short" });
}

// A recording ticks from its start; the rest show their saved length.
export function Duration({ meeting, recordingStartedAt }: { meeting: Meeting; recordingStartedAt: number | null }) {
  const live = meeting.state === "recording" && recordingStartedAt !== null;
  const now = useNow(live);
  return <>{formatClock(live ? now - recordingStartedAt : meeting.durationMs)}</>;
}

export function StateBadge({ state }: { state: MeetingState }) {
  return (
    <span className="state-badge" data-state={state}>
      {STATE_LABELS[state]}
    </span>
  );
}

// Start meeting, or Stop with the elapsed time while one records.
export function RecordButton({ state }: { state: AppState }) {
  const now = useNow(state.phase === "recording");
  switch (state.phase) {
    case "idle":
      return (
        <button className="btn btn-secondary" onClick={() => void lechuza.startMeeting()}>
          <CircleDot /> Start meeting
        </button>
      );
    case "starting":
      return (
        <button className="btn btn-secondary" disabled>
          <CircleDot /> Starting…
        </button>
      );
    case "recording":
      return (
        <button className="btn btn-primary btn-clock" onClick={() => void lechuza.stopMeeting()}>
          <Square /> Stop meeting · {formatClock(now - (state.recording?.startedAt ?? now))}
        </button>
      );
    case "stopping":
      return (
        <button className="btn btn-secondary" disabled>
          Saving…
        </button>
      );
  }
}

// Copies the meeting's transcript, then shows a tick for a moment.
export function CopyTranscriptButton({ id, iconOnly = false }: { id: string; iconOnly?: boolean }) {
  const [copied, setCopied] = useState(false);
  const copy = async () => {
    await lechuza.copyTranscript(id);
    setCopied(true);
    setTimeout(() => setCopied(false), 1500);
  };
  const Icon = copied ? Check : Copy;
  if (iconOnly) {
    return (
      <button className="icon-button icon-button-small" title="Copy transcript" onClick={() => void copy()}>
        <Icon />
      </button>
    );
  }
  return (
    <button className="btn btn-secondary" onClick={() => void copy()}>
      <Icon /> {copied ? "Copied" : "Copy transcript"}
    </button>
  );
}

export function EmptyState(props: { icon: LucideIcon; title: string; children: ReactNode; action?: ReactNode }) {
  return (
    <div className="empty">
      <span className="empty-icon">
        <props.icon />
      </span>
      <div>
        <p className="empty-title">{props.title}</p>
        <p className="empty-text">{props.children}</p>
      </div>
      {props.action}
    </div>
  );
}
