import { createReadStream } from "node:fs";
import * as fs from "node:fs/promises";
import { Readable } from "node:stream";

import type { MeetingLibrary } from "./library.ts";

type Range = { start: number; end: number } | "unsatisfiable" | null;

// Parses a single `bytes=start-end` range header against a file size; null
// when there is no usable header, so the whole file is served.
function parseRange(header: string | null, size: number): Range {
  const match = header?.match(/^bytes=(\d*)-(\d*)$/);
  if (!match) return null;
  const [, rawStart = "", rawEnd = ""] = match;
  if (rawStart === "" && rawEnd === "") return null;
  if (rawStart === "") {
    const suffix = Math.min(Number(rawEnd), size);
    return suffix > 0 ? { start: size - suffix, end: size - 1 } : "unsatisfiable";
  }
  const start = Number(rawStart);
  const end = rawEnd === "" ? size - 1 : Math.min(Number(rawEnd), size - 1);
  return start < size && start <= end ? { start, end } : "unsatisfiable";
}

// Serves lechuza-media://meeting/<id>: that meeting's mix, with byte ranges
// so the player can seek.
export async function handleMediaRequest(library: MeetingLibrary, request: Request): Promise<Response> {
  const id = decodeURIComponent(new URL(request.url).pathname.replace(/^\//, ""));
  const file = library.mixFile(id);
  const stat = file ? await fs.stat(file).catch(() => null) : null;
  if (!file || !stat) return new Response("Not found", { status: 404 });

  const headers = { "Content-Type": "audio/mp4", "Accept-Ranges": "bytes" };
  const body = (start: number, end: number) => Readable.toWeb(createReadStream(file, { start, end }));
  const range = parseRange(request.headers.get("range"), stat.size);

  if (range === "unsatisfiable") {
    return new Response(null, { status: 416, headers: { ...headers, "Content-Range": `bytes */${stat.size}` } });
  }
  if (!range) {
    return new Response(stat.size === 0 ? null : body(0, stat.size - 1), {
      headers: { ...headers, "Content-Length": String(stat.size) },
    });
  }
  return new Response(body(range.start, range.end), {
    status: 206,
    headers: {
      ...headers,
      "Content-Length": String(range.end - range.start + 1),
      "Content-Range": `bytes ${range.start}-${range.end}/${stat.size}`,
    },
  });
}
