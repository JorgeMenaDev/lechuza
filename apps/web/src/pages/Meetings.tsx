import { FileText, LoaderCircle, Mic, TriangleAlert } from "lucide-react";
import { Fragment, useState } from "react";

import type { AppState, Meeting, MeetingState } from "@lechuza/contracts";

import { useTranscript } from "../bridge";
import { groupByDay } from "../lib/activity";
import { Duration, EmptyState, RecordButton, StateBadge, formatDay, formatTime } from "../ui";

// The Meetings list: every meeting by day, newest first. The side pane
// previews the meeting under the pointer (the newest one otherwise); a click
// opens it.

const PREVIEW_LINES = 12;

export function Meetings({ state, onOpenMeeting }: { state: AppState; onOpenMeeting: (id: string) => void }) {
  const [previewId, setPreviewId] = useState<string | null>(null);
  const preview = state.meetings.find((meeting) => meeting.id === previewId) ?? state.meetings[0] ?? null;
  const recordingStartedAt = state.recording?.startedAt ?? null;
  return (
    <div className="split">
      <div className="page">
        <header className="page-header">
          <h1 className="page-title">Meetings</h1>
          <RecordButton state={state} />
        </header>
        {state.meetings.length === 0 ? (
          <EmptyState icon={Mic} title="No meetings yet">
            Start one here or from the owl in the menu bar. Lechuza records you and the call, then transcribes both on
            this Mac.
          </EmptyState>
        ) : (
          groupByDay(state.meetings, (meeting) => meeting.startedAt, new Date()).map((group) => (
            <section key={group.label} className="day-group">
              <h2 className="group-label group-label-inset">{group.label}</h2>
              <ul className="note-list">
                {group.items.map((meeting) => (
                  <li key={meeting.id}>
                    <button
                      className="note-row"
                      data-previewed={meeting.id === preview?.id}
                      onMouseEnter={() => setPreviewId(meeting.id)}
                      onFocus={() => setPreviewId(meeting.id)}
                      onClick={() => onOpenMeeting(meeting.id)}
                    >
                      <span className="note-icon" data-state={meeting.state}>
                        <NoteIcon meeting={meeting} />
                      </span>
                      <span className="note-text">
                        <span className="note-title">{meeting.title}</span>
                        <span className="note-meta">
                          {formatTime(meeting.startedAt)} ·{" "}
                          <Duration meeting={meeting} recordingStartedAt={recordingStartedAt} />
                        </span>
                      </span>
                      {meeting.state !== "ready" && <StateBadge state={meeting.state} />}
                    </button>
                  </li>
                ))}
              </ul>
            </section>
          ))
        )}
      </div>
      <aside className="pane" aria-label="Preview">
        {preview && <Preview key={preview.id} meeting={preview} />}
      </aside>
    </div>
  );
}

function NoteIcon({ meeting }: { meeting: Meeting }) {
  switch (meeting.state) {
    case "recording":
      return <span className="rec-dot" />;
    case "transcribing":
      return <LoaderCircle className="spin" />;
    case "failed":
      return <TriangleAlert />;
    case "ready":
      return <FileText />;
  }
}

const PREVIEW_STATUS: Record<Exclude<MeetingState, "ready">, string> = {
  recording: "Recording now. The transcript appears when you stop.",
  transcribing: "Transcribing on this Mac…",
  failed: "Couldn't transcribe this meeting. Open it to retry.",
};

function Preview({ meeting }: { meeting: Meeting }) {
  const lines = useTranscript(meeting);
  return (
    <>
      <header className="pane-header">
        <h2 className="pane-title">{meeting.title}</h2>
        <p className="pane-meta">
          {formatDay(meeting.startedAt)} • {formatTime(meeting.startedAt)}
        </p>
      </header>
      <div className="pane-body">
        <h3 className="pane-label">Transcript</h3>
        {meeting.state !== "ready" ? (
          <p className="pane-text pane-text-muted">{PREVIEW_STATUS[meeting.state]}</p>
        ) : lines.length === 0 ? (
          <p className="pane-text pane-text-muted">Nobody spoke in this meeting.</p>
        ) : (
          <p className="pane-text">
            {lines.slice(0, PREVIEW_LINES).map((line, index) => (
              <Fragment key={`${line.startMs}-${index}`}>
                <span className="speaker" data-speaker={line.speaker}>
                  {line.speaker}
                </span>{" "}
                {line.text}{" "}
              </Fragment>
            ))}
          </p>
        )}
      </div>
    </>
  );
}
