import type { Meeting } from "@lechuza/contracts";

// Grouping and totals for Home and the Meetings list. `now` is passed in so
// the day boundaries are testable; dates are in the Mac's time zone.

export interface DayGroup<T> {
  // "Today", "Yesterday", or a date like "Fri, 16 Oct".
  readonly label: string;
  readonly items: ReadonlyArray<T>;
}

function startOfDay(date: Date): number {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime();
}

function dayLabel(dayStart: number, now: Date): string {
  const today = startOfDay(now);
  if (dayStart === today) return "Today";
  if (dayStart === startOfDay(new Date(today - 1))) return "Yesterday";
  return new Date(dayStart).toLocaleDateString(undefined, { weekday: "short", day: "numeric", month: "short" });
}

// Items grouped by the day they started, keeping their order (newest first).
export function groupByDay<T>(items: ReadonlyArray<T>, startedAt: (item: T) => string, now: Date): DayGroup<T>[] {
  const groups: { day: number; items: T[] }[] = [];
  for (const item of items) {
    const day = startOfDay(new Date(startedAt(item)));
    const last = groups.at(-1);
    if (last?.day === day) last.items.push(item);
    else groups.push({ day, items: [item] });
  }
  return groups.map((group) => ({ label: dayLabel(group.day, now), items: group.items }));
}

export interface MeetingStats {
  readonly count: number;
  readonly recordedMs: number;
  // Meetings since Monday.
  readonly thisWeek: number;
}

export function meetingStats(meetings: ReadonlyArray<Meeting>, now: Date): MeetingStats {
  const monday = new Date(now.getFullYear(), now.getMonth(), now.getDate() - ((now.getDay() + 6) % 7)).getTime();
  return {
    count: meetings.length,
    recordedMs: meetings.reduce((total, meeting) => total + meeting.durationMs, 0),
    thisWeek: meetings.filter((meeting) => Date.parse(meeting.startedAt) >= monday).length,
  };
}
