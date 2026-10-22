import { AudioLines } from "lucide-react";

import type { AppState, Meeting } from "@lechuza/contracts";

import { groupByDay, meetingStats } from "../lib/activity";
import { CopyTranscriptButton, Duration, EmptyState, StateBadge, formatTime } from "../ui";

// Home: a greeting, recent activity by day, and totals. Activity is meetings
// for now; dictations (#4) join the same day groups.

const RECENT = 20;

export function Home({ state, onOpenMeeting }: { state: AppState; onOpenMeeting: (id: string) => void }) {
  const name = state.info.firstName;
  const recent = state.meetings.slice(0, RECENT);
  const recordingStartedAt = state.recording?.startedAt ?? null;
  return (
    <div className="page">
      <h1 className="page-title">{name ? `Welcome back, ${name}` : "Welcome back"}</h1>
      <div className="home-columns">
        <section aria-label="Recent activity">
          {recent.length === 0 ? (
            <EmptyState icon={AudioLines} title="Nothing here yet">
              Start a meeting from the owl in the menu bar or on the Meetings page. It shows up here.
            </EmptyState>
          ) : (
            groupByDay(recent, (meeting) => meeting.startedAt, new Date()).map((group) => (
              <section key={group.label} className="day-group">
                <h2 className="group-label">{group.label}</h2>
                <ul className="history">
                  {group.items.map((meeting) => (
                    <ActivityRow
                      key={meeting.id}
                      meeting={meeting}
                      recordingStartedAt={recordingStartedAt}
                      onOpen={() => onOpenMeeting(meeting.id)}
                    />
                  ))}
                </ul>
              </section>
            ))
          )}
        </section>
        <Stats meetings={state.meetings} />
      </div>
    </div>
  );
}

function ActivityRow(props: { meeting: Meeting; recordingStartedAt: number | null; onOpen: () => void }) {
  const { meeting } = props;
  return (
    <li className="history-row">
      <button className="history-open" onClick={props.onOpen}>
        <span className="history-time">{formatTime(meeting.startedAt)}</span>
        <span className="history-text">
          {meeting.title}
          <span className="history-meta">
            <Duration meeting={meeting} recordingStartedAt={props.recordingStartedAt} />
          </span>
          {meeting.state !== "ready" && <StateBadge state={meeting.state} />}
        </span>
      </button>
      {meeting.state === "ready" && (
        <div className="history-actions">
          <CopyTranscriptButton id={meeting.id} iconOnly />
        </div>
      )}
    </li>
  );
}

function plural(count: string, word: string): string {
  return count === "1" ? word : `${word}s`;
}

function Stats({ meetings }: { meetings: ReadonlyArray<Meeting> }) {
  const stats = meetingStats(meetings, new Date());
  const hours = stats.recordedMs / 3_600_000;
  const recorded =
    hours >= 1
      ? { value: hours.toLocaleString(undefined, { maximumFractionDigits: 1 }), unit: "hour" }
      : { value: String(Math.round(stats.recordedMs / 60_000)), unit: "minute" };
  const rows = [
    { value: String(stats.count), label: plural(String(stats.count), "meeting") },
    { value: recorded.value, label: `${plural(recorded.value, recorded.unit)} recorded` },
    { value: String(stats.thisWeek), label: "this week" },
  ];
  return (
    <aside className="stats" aria-label="Totals">
      {rows.map((row) => (
        <p key={row.label} className="stat">
          <span className="stat-value">{row.value}</span>
          <span className="stat-label">{row.label}</span>
        </p>
      ))}
    </aside>
  );
}
