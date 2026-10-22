import { useEffect, useRef, useState } from "react";

import {
  formatClock,
  type AppState,
  type Meeting,
  type MeetingState,
  type ModelStatus,
  type TranscriptLine,
} from "@lechuza/contracts";

import { lechuza, useAppState, useLevels, useNow } from "../bridge";
import { activeLineIndex } from "../lib/transcript";

// The Meetings page: every meeting, newest first, and the selected one with
// its player and transcript. Styles live in index.css under the class names.

const STATE_LABELS: Record<MeetingState, string> = {
  recording: "Recording",
  transcribing: "Transcribing",
  ready: "Ready",
  failed: "Failed",
};

function formatDate(iso: string): string {
  return new Date(iso).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });
}

export function Meetings() {
  const state = useAppState();
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const recordingId = state?.recording?.id ?? null;
  // A new recording opens itself.
  useEffect(() => {
    if (recordingId) setSelectedId(recordingId);
  }, [recordingId]);

  if (!state) return null;
  const selected = state.meetings.find((meeting) => meeting.id === selectedId) ?? state.meetings[0] ?? null;
  return (
    <div className="app">
      <header className="titlebar">
        <h1 className="titlebar-title">Meetings</h1>
        <RecordButton state={state} />
      </header>
      <Banners state={state} />
      <div className="meetings">
        <MeetingList
          meetings={state.meetings}
          selectedId={selected?.id ?? null}
          recordingStartedAt={state.recording?.startedAt ?? null}
          onSelect={setSelectedId}
        />
        {selected ? (
          <MeetingDetail
            key={selected.id}
            meeting={selected}
            model={state.model}
            recordingStartedAt={state.recording?.startedAt ?? null}
          />
        ) : (
          <section className="meeting-detail meeting-detail-empty" />
        )}
      </div>
    </div>
  );
}

function RecordButton({ state }: { state: AppState }) {
  const now = useNow(state.phase === "recording");
  switch (state.phase) {
    case "idle":
      return (
        <button className="btn btn-primary" onClick={() => void lechuza.startMeeting()}>
          Start meeting
        </button>
      );
    case "starting":
      return (
        <button className="btn btn-primary" disabled>
          Starting…
        </button>
      );
    case "recording":
      return (
        <button className="btn btn-stop" onClick={() => void lechuza.stopMeeting()}>
          Stop meeting · {formatClock(now - (state.recording?.startedAt ?? now))}
        </button>
      );
    case "stopping":
      return (
        <button className="btn" disabled>
          Saving…
        </button>
      );
  }
}

function Banners({ state }: { state: AppState }) {
  const { notice, model } = state;
  return (
    <>
      {notice && (
        <div className="banner banner-warning" role="alert">
          <span>{notice}</span>
          <button className="btn btn-quiet" onClick={() => void lechuza.dismissNotice()}>
            Dismiss
          </button>
        </div>
      )}
      {model.state === "downloading" && (
        <div className="banner" role="status">
          <span>
            {model.phase === "compiling"
              ? "Preparing the speech model…"
              : `Downloading the speech model (about 600 MB, only once)… ${Math.round(model.fraction * 100)}%`}
          </span>
          <progress className="banner-progress" value={model.fraction} />
        </div>
      )}
      {model.state === "failed" && (
        <div className="banner banner-warning" role="alert">
          <span>
            Couldn't download the speech model: {model.message} Lechuza tries again with the next transcription.
          </span>
        </div>
      )}
    </>
  );
}

// A recording ticks from its start; the rest show their saved length.
function Duration({ meeting, recordingStartedAt }: { meeting: Meeting; recordingStartedAt: number | null }) {
  const live = meeting.state === "recording" && recordingStartedAt !== null;
  const now = useNow(live);
  return <>{formatClock(live ? now - recordingStartedAt : meeting.durationMs)}</>;
}

function StateBadge({ state }: { state: MeetingState }) {
  return (
    <span className="badge" data-state={state}>
      {STATE_LABELS[state]}
    </span>
  );
}

function MeetingList(props: {
  meetings: ReadonlyArray<Meeting>;
  selectedId: string | null;
  recordingStartedAt: number | null;
  onSelect: (id: string) => void;
}) {
  if (props.meetings.length === 0) {
    return (
      <aside className="meeting-list meeting-list-empty">
        No meetings yet. Start one here or from the owl in the menu bar.
      </aside>
    );
  }
  return (
    <ul className="meeting-list" aria-label="Meetings">
      {props.meetings.map((meeting) => (
        <li key={meeting.id}>
          <button
            className="meeting-row"
            aria-current={meeting.id === props.selectedId}
            onClick={() => props.onSelect(meeting.id)}
          >
            <span className="meeting-row-title">{meeting.title}</span>
            <span className="meeting-row-meta">
              {formatDate(meeting.startedAt)} · <Duration meeting={meeting} recordingStartedAt={props.recordingStartedAt} />
            </span>
            <StateBadge state={meeting.state} />
          </button>
        </li>
      ))}
    </ul>
  );
}

// The transcript once the meeting is ready; empty before.
function useTranscript(meeting: Meeting): ReadonlyArray<TranscriptLine> {
  const [lines, setLines] = useState<ReadonlyArray<TranscriptLine>>([]);
  const ready = meeting.state === "ready";
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

function MeetingDetail(props: { meeting: Meeting; model: ModelStatus; recordingStartedAt: number | null }) {
  const { meeting } = props;
  const audio = useRef<HTMLAudioElement>(null);
  const [positionMs, setPositionMs] = useState(0);
  const lines = useTranscript(meeting);

  const seek = (ms: number) => {
    if (!audio.current) return;
    audio.current.currentTime = ms / 1000;
    void audio.current.play();
  };

  return (
    <section className="meeting-detail" aria-label={meeting.title}>
      <TitleEditor meeting={meeting} />
      <p className="meeting-detail-meta">
        {formatDate(meeting.startedAt)} · <Duration meeting={meeting} recordingStartedAt={props.recordingStartedAt} />{" "}
        <StateBadge state={meeting.state} />
      </p>
      <MeetingActions meeting={meeting} hasTranscript={lines.length > 0} />

      {meeting.state === "recording" && <LevelMeters />}
      {meeting.state === "transcribing" && (
        <p className="meeting-status">
          {props.model.state === "downloading" ? "Waiting for the speech model…" : "Transcribing…"}
        </p>
      )}
      {meeting.state === "failed" && (
        <div className="meeting-error" role="alert">
          <p>
            <strong>Couldn't transcribe this meeting.</strong> {meeting.error}
          </p>
          <button className="btn" onClick={() => void lechuza.retryTranscription(meeting.id)}>
            Retry
          </button>
        </div>
      )}

      {meeting.audioUrl && (
        <audio
          ref={audio}
          className="player"
          controls
          preload="metadata"
          src={meeting.audioUrl}
          onTimeUpdate={(event) => setPositionMs(event.currentTarget.currentTime * 1000)}
        />
      )}
      {meeting.state === "ready" && lines.length === 0 && <p className="meeting-status">Nobody spoke in this meeting.</p>}
      <Transcript lines={lines} active={activeLineIndex(lines, positionMs)} onSeek={seek} />
    </section>
  );
}

// Click the title to rename; Enter or clicking away saves, Escape cancels.
function TitleEditor({ meeting }: { meeting: Meeting }) {
  const [editing, setEditing] = useState(false);
  // The first of Enter, Escape or blur ends the edit; later ones are ignored.
  const done = useRef(false);
  const finish = (title: string | null) => {
    if (done.current) return;
    done.current = true;
    setEditing(false);
    const trimmed = title?.trim();
    if (trimmed && trimmed !== meeting.title) void lechuza.renameMeeting(meeting.id, trimmed);
  };

  if (!editing) {
    return (
      <h2 className="meeting-title">
        <button
          className="meeting-title-button"
          title="Rename"
          disabled={meeting.state === "recording"}
          onClick={() => {
            done.current = false;
            setEditing(true);
          }}
        >
          {meeting.title}
        </button>
      </h2>
    );
  }
  return (
    <input
      className="meeting-title-input"
      aria-label="Meeting title"
      defaultValue={meeting.title}
      autoFocus
      onFocus={(event) => event.currentTarget.select()}
      onBlur={(event) => finish(event.currentTarget.value)}
      onKeyDown={(event) => {
        if (event.key === "Enter") finish(event.currentTarget.value);
        if (event.key === "Escape") finish(null);
      }}
    />
  );
}

function MeetingActions({ meeting, hasTranscript }: { meeting: Meeting; hasTranscript: boolean }) {
  const [copied, setCopied] = useState(false);
  const [confirming, setConfirming] = useState(false);
  const busy = meeting.state === "recording" || meeting.state === "transcribing";

  const copy = async () => {
    await lechuza.copyTranscript(meeting.id);
    setCopied(true);
    setTimeout(() => setCopied(false), 1500);
  };

  return (
    <div className="meeting-actions">
      <button className="btn" disabled={!hasTranscript} onClick={() => void copy()}>
        {copied ? "Copied" : "Copy transcript"}
      </button>
      <button className="btn" onClick={() => void lechuza.revealMeeting(meeting.id)}>
        Show in Finder
      </button>
      {confirming ? (
        <>
          <button className="btn btn-danger" onClick={() => void lechuza.trashMeeting(meeting.id)}>
            Move to Trash
          </button>
          <button className="btn btn-quiet" onClick={() => setConfirming(false)}>
            Cancel
          </button>
        </>
      ) : (
        <button className="btn" disabled={busy} onClick={() => setConfirming(true)}>
          Delete
        </button>
      )}
    </div>
  );
}

function LevelMeters() {
  const levels = useLevels();
  return (
    <div className="levels" aria-label="Input levels">
      <Meter label="Me" value={levels.mic} />
      <Meter label="Them" value={levels.system} />
    </div>
  );
}

function Meter({ label, value }: { label: string; value: number }) {
  // Peaks are linear; the square root reads closer to how loud it sounds.
  return (
    <div className="meter">
      <span className="meter-label">{label}</span>
      <span className="meter-track">
        <span className="meter-fill" style={{ width: `${Math.min(1, Math.sqrt(value)) * 100}%` }} />
      </span>
    </div>
  );
}

function Transcript(props: { lines: ReadonlyArray<TranscriptLine>; active: number; onSeek: (ms: number) => void }) {
  const activeLine = useRef<HTMLLIElement>(null);
  useEffect(() => activeLine.current?.scrollIntoView({ block: "nearest" }), [props.active]);
  if (props.lines.length === 0) return null;
  return (
    <ol className="transcript" aria-label="Transcript">
      {props.lines.map((line, index) => (
        <li key={`${line.startMs}-${index}`} ref={index === props.active ? activeLine : undefined}>
          <button
            className="line"
            data-active={index === props.active}
            data-speaker={line.speaker}
            onClick={() => props.onSeek(line.startMs)}
          >
            <span className="line-time">{formatClock(line.startMs)}</span>
            <span className="line-speaker">{line.speaker}</span>
            <span className="line-text">{line.text}</span>
          </button>
        </li>
      ))}
    </ol>
  );
}
