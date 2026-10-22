import { AudioLines, Check } from "lucide-react";
import type { ReactNode } from "react";

import type { AppState, Dictation, DictationState, DictationStats, Hotkey, Meeting } from "@lechuza/contracts";

import { lechuza } from "../bridge";
import { groupByDay, meetingStats, mergeActivity } from "../lib/activity";
import { CopyButton, Duration, EmptyState, HOTKEY_NAMES, StateBadge, formatTime } from "../ui";

// Home: a greeting, the dictation setup until it is done, recent meetings and
// dictations by day, and totals.

const RECENT = 100;

export function Home({ state, onOpenMeeting }: { state: AppState; onOpenMeeting: (id: string) => void }) {
  const name = state.info.firstName;
  const recent = mergeActivity(state.meetings, state.dictation.recent).slice(0, RECENT);
  const recordingStartedAt = state.recording?.startedAt ?? null;
  const key = HOTKEY_NAMES[state.settings.hotkey].key;
  return (
    <div className="page">
      <h1 className="page-title">{name ? `Welcome back, ${name}` : "Welcome back"}</h1>
      <SetUpDictation dictation={state.dictation} hotkey={state.settings.hotkey} />
      <div className="home-columns">
        <section aria-label="Recent activity">
          {recent.length === 0 ? (
            <EmptyState icon={AudioLines} title="Nothing here yet">
              Hold {key} in any app and speak, or start a meeting from the owl in the menu bar. It shows up here.
            </EmptyState>
          ) : (
            groupByDay(recent, (activity) => activity.item.startedAt, new Date()).map((group) => (
              <section key={group.label} className="day-group">
                <h2 className="group-label">{group.label}</h2>
                <ul className="history">
                  {group.items.map((activity) =>
                    activity.kind === "meeting" ? (
                      <MeetingRow
                        key={activity.item.id}
                        meeting={activity.item}
                        recordingStartedAt={recordingStartedAt}
                        onOpen={() => onOpenMeeting(activity.item.id)}
                      />
                    ) : (
                      <DictationRow key={activity.item.id} dictation={activity.item} />
                    ),
                  )}
                </ul>
              </section>
            ))
          )}
        </section>
        <Stats meetings={state.meetings} dictation={state.dictation.stats} />
      </div>
    </div>
  );
}

// Shown until Lechuza has Accessibility and, with fn as the hotkey, macOS
// leaves the 🌐 key alone.
function SetUpDictation({ dictation, hotkey }: { dictation: DictationState; hotkey: Hotkey }) {
  if (dictation.accessibility && !dictation.fnConflict) return null;
  const key = HOTKEY_NAMES[hotkey].key;
  return (
    <section className="setup" aria-label="Set up dictation">
      <h2 className="setup-title">Dictate in any app</h2>
      <p className="setup-text">
        Hold {key} and speak, or press it twice to talk hands-free. Your words appear where the cursor is.
      </p>
      <ol className="setup-steps">
        <SetupStep
          done={dictation.accessibility}
          action={
            <button className="btn btn-primary" onClick={() => void lechuza.requestAccessibility()}>
              Allow Accessibility
            </button>
          }
        >
          Allow Accessibility, so Lechuza can hear {key} in every app and paste your words.
        </SetupStep>
        {hotkey === "fn" && (
          <SetupStep
            done={!dictation.fnConflict}
            action={
              <button className="btn btn-secondary" onClick={() => void lechuza.openExternal("keyboard-settings")}>
                Open Keyboard Settings
              </button>
            }
          >
            Set "Press 🌐 key to" to "Do Nothing" in Keyboard settings, so macOS doesn't also act on fn.
          </SetupStep>
        )}
      </ol>
    </section>
  );
}

function SetupStep(props: { done: boolean; action: ReactNode; children: ReactNode }) {
  return (
    <li className="setup-step" data-done={props.done}>
      <span className="setup-check">{props.done && <Check />}</span>
      <span className="setup-step-text">{props.children}</span>
      {!props.done && props.action}
    </li>
  );
}

function MeetingRow(props: { meeting: Meeting; recordingStartedAt: number | null; onOpen: () => void }) {
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
          <CopyButton label="Copy transcript" copy={() => lechuza.copyTranscript(meeting.id)} iconOnly />
        </div>
      )}
    </li>
  );
}

function DictationRow({ dictation }: { dictation: Dictation }) {
  return (
    <li className="history-row">
      <div className="history-entry">
        <span className="history-time">{formatTime(dictation.startedAt)}</span>
        <p className="history-dictation">{dictation.text}</p>
      </div>
      <div className="history-actions">
        <CopyButton label="Copy" copy={() => lechuza.copyDictation(dictation.id)} iconOnly />
      </div>
    </li>
  );
}

function plural(count: string, word: string): string {
  return count === "1" ? word : `${word}s`;
}

const compact = new Intl.NumberFormat(undefined, { notation: "compact", maximumFractionDigits: 1 });

function Stats({ meetings, dictation }: { meetings: ReadonlyArray<Meeting>; dictation: DictationStats }) {
  const stats = meetingStats(meetings, new Date());
  const hours = stats.recordedMs / 3_600_000;
  const recorded =
    hours >= 1
      ? { value: hours.toLocaleString(undefined, { maximumFractionDigits: 1 }), unit: "hour" }
      : { value: String(Math.round(stats.recordedMs / 60_000)), unit: "minute" };
  const words = compact.format(dictation.words);
  const rows = [
    { value: words, label: `${plural(words, "word")} dictated` },
    { value: String(dictation.wordsPerMinute), label: "wpm" },
    { value: String(stats.count), label: plural(String(stats.count), "meeting") },
    { value: recorded.value, label: `${plural(recorded.value, recorded.unit)} recorded` },
    { value: String(stats.thisWeek), label: `${plural(String(stats.thisWeek), "meeting")} this week` },
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
