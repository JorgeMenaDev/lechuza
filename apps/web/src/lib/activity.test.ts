import { describe, expect, test } from "bun:test";

import type { Meeting } from "@lechuza/contracts";

import { groupByDay, meetingStats } from "./activity.ts";

// Thursday 22 October 2026, 15:00 local time.
const now = new Date(2026, 9, 22, 15, 0);

function meeting(id: string, startedAt: Date, minutes: number): Meeting {
  return {
    id,
    title: id,
    startedAt: startedAt.toISOString(),
    durationMs: minutes * 60_000,
    state: "ready",
    error: null,
    audioUrl: null,
  };
}

const meetings = [
  meeting("standup", new Date(2026, 9, 22, 9, 30), 15),
  meeting("review", new Date(2026, 9, 22, 0, 5), 30),
  meeting("late call", new Date(2026, 9, 21, 23, 50), 45),
  meeting("monday", new Date(2026, 9, 19, 10, 0), 60),
  meeting("last week", new Date(2026, 9, 18, 10, 0), 20),
];

describe("groupByDay", () => {
  test("groups by local day, newest first, with Today and Yesterday by name", () => {
    const groups = groupByDay(meetings, (item) => item.startedAt, now);
    expect(groups.map((group) => group.items.map((item) => item.id))).toEqual([
      ["standup", "review"],
      ["late call"],
      ["monday"],
      ["last week"],
    ]);
    expect(groups[0]?.label).toBe("Today");
    expect(groups[1]?.label).toBe("Yesterday");
  });
});

describe("meetingStats", () => {
  test("counts meetings, recorded time and meetings since Monday", () => {
    expect(meetingStats(meetings, now)).toEqual({ count: 5, recordedMs: 170 * 60_000, thisWeek: 4 });
  });
});
