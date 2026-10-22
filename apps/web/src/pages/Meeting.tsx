import { ChevronLeft, FolderOpen, Pause, Play, RotateCcw, Trash2 } from "lucide-react";
import { useEffect, useRef, useState, type RefObject } from "react";

import { formatClock, type AppState, type Meeting as MeetingData, type TranscriptLine } from "@lechuza/contracts";

import { lechuza, useLevels, useTranscript } from "../bridge";
import { activeLineIndex } from "../lib/transcript";
import { CopyButton, Duration, RecordButton, StateBadge, formatDay, formatTime } from "../ui";

// One meeting: its player and transcript. The line being spoken lights up;
// a click on a line plays from there.

export function Meeting(props: { meeting: MeetingData; state: AppState; onBack: () => void }) {
  const { meeting, state } = props;
  const audio = useRef<HTMLAudioElement>(null);
  const [positionMs, setPositionMs] = useState(0);
  const lines = useTranscript(meeting);

  const seek = (ms: number) => {
    if (!audio.current) return;
    audio.current.currentTime = ms / 1000;
    void audio.current.play();
  };

  return (
    <div className="page">
      <div className="meeting">
        <div className="meeting-toolbar">
          <button className="back-button" onClick={props.onBack}>
            <ChevronLeft /> Meetings
          </button>
          <MeetingActions meeting={meeting} hasTranscript={lines.length > 0} onDeleted={props.onBack} />
        </div>
        <TitleEditor meeting={meeting} />
        <p className="meeting-meta">
          {formatDay(meeting.startedAt)} • {formatTime(meeting.startedAt)} •{" "}
          <Duration meeting={meeting} recordingStartedAt={state.recording?.startedAt ?? null} />
          {meeting.state !== "ready" && <StateBadge state={meeting.state} />}
        </p>

        {meeting.state === "recording" && <Recorder state={state} />}
        {meeting.state === "transcribing" && (
          <p className="meeting-status">
            {state.model.state === "downloading" ? "Waiting for the speech model…" : "Transcribing on this Mac…"}
          </p>
        )}
        {meeting.state === "failed" && (
          <div className="meeting-error" role="alert">
            <p>
              <strong>Couldn't transcribe this meeting.</strong> {meeting.error}
            </p>
            <button className="btn btn-secondary" onClick={() => void lechuza.retryTranscription(meeting.id)}>
              <RotateCcw /> Retry
            </button>
          </div>
        )}

        {meeting.audioUrl && (
          <Player
            audio={audio}
            src={meeting.audioUrl}
            lengthMs={meeting.durationMs}
            positionMs={positionMs}
            onPosition={setPositionMs}
          />
        )}
        {meeting.state === "ready" && lines.length === 0 && (
          <p className="meeting-status">Nobody spoke in this meeting.</p>
        )}
        <Transcript lines={lines} active={activeLineIndex(lines, positionMs)} onSeek={seek} />
      </div>
    </div>
  );
}

// Click the title to rename; Enter or clicking away saves, Escape cancels.
function TitleEditor({ meeting }: { meeting: MeetingData }) {
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
      <h1 className="meeting-title">
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
      </h1>
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

function MeetingActions(props: { meeting: MeetingData; hasTranscript: boolean; onDeleted: () => void }) {
  const { meeting } = props;
  const [confirming, setConfirming] = useState(false);
  const busy = meeting.state === "recording" || meeting.state === "transcribing";

  if (confirming) {
    return (
      <div className="meeting-actions">
        <button className="btn btn-outline" onClick={() => setConfirming(false)}>
          Cancel
        </button>
        <button
          className="btn btn-danger"
          onClick={() => void lechuza.trashMeeting(meeting.id).then(props.onDeleted)}
        >
          <Trash2 /> Move to Trash
        </button>
      </div>
    );
  }
  return (
    <div className="meeting-actions">
      <button className="icon-button" title="Show in Finder" onClick={() => void lechuza.revealMeeting(meeting.id)}>
        <FolderOpen />
      </button>
      <button className="icon-button" title="Delete" disabled={busy} onClick={() => setConfirming(true)}>
        <Trash2 />
      </button>
      {props.hasTranscript && <CopyButton label="Copy transcript" copy={() => lechuza.copyTranscript(meeting.id)} />}
    </div>
  );
}

// Live levels for both tracks, with Stop.
function Recorder({ state }: { state: AppState }) {
  const levels = useLevels();
  return (
    <div className="recorder">
      <div className="levels" aria-label="Input levels">
        <Meter speaker="me" value={levels.mic} />
        <Meter speaker="them" value={levels.system} />
      </div>
      <RecordButton state={state} />
    </div>
  );
}

function Meter({ speaker, value }: { speaker: "me" | "them"; value: number }) {
  // Peaks are linear; the square root reads closer to how loud it sounds.
  return (
    <div className="meter" data-speaker={speaker}>
      <span className="meter-label">{speaker}</span>
      <span className="meter-track">
        <span className="meter-fill" style={{ width: `${Math.min(1, Math.sqrt(value)) * 100}%` }} />
      </span>
    </div>
  );
}

function Player(props: {
  audio: RefObject<HTMLAudioElement | null>;
  src: string;
  lengthMs: number;
  positionMs: number;
  onPosition: (ms: number) => void;
}) {
  const [playing, setPlaying] = useState(false);
  const [lengthMs, setLengthMs] = useState(props.lengthMs);
  const progress = lengthMs > 0 ? Math.min(1, props.positionMs / lengthMs) : 0;
  const toggle = () => {
    const audio = props.audio.current;
    if (!audio) return;
    if (audio.paused) void audio.play();
    else audio.pause();
  };
  return (
    <div className="player">
      <audio
        ref={props.audio}
        src={props.src}
        preload="metadata"
        onPlay={() => setPlaying(true)}
        onPause={() => setPlaying(false)}
        onLoadedMetadata={(event) => {
          const seconds = event.currentTarget.duration;
          if (Number.isFinite(seconds)) setLengthMs(seconds * 1000);
        }}
        onTimeUpdate={(event) => props.onPosition(event.currentTarget.currentTime * 1000)}
      />
      <button className="player-toggle" aria-label={playing ? "Pause" : "Play"} onClick={toggle}>
        {playing ? <Pause /> : <Play />}
      </button>
      <input
        className="player-seek"
        type="range"
        aria-label="Position"
        min={0}
        max={lengthMs}
        step={100}
        value={Math.min(props.positionMs, lengthMs)}
        style={{ backgroundSize: `${progress * 100}% 100%` }}
        onChange={(event) => {
          const ms = Number(event.currentTarget.value);
          if (props.audio.current) props.audio.current.currentTime = ms / 1000;
          props.onPosition(ms);
        }}
      />
      <span className="player-time">
        {formatClock(props.positionMs)} / {formatClock(lengthMs)}
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
          <button className="line" data-active={index === props.active} onClick={() => props.onSeek(line.startMs)}>
            <span className="line-time">{formatClock(line.startMs)}</span>
            <span className="line-text">
              <span className="speaker" data-speaker={line.speaker}>
                {line.speaker}
              </span>{" "}
              {line.text}
            </span>
          </button>
        </li>
      ))}
    </ol>
  );
}
