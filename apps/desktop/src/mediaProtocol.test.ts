import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import * as fs from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";

import { MeetingLibrary } from "./library.ts";
import { handleMediaRequest } from "./mediaProtocol.ts";

let root: string;
let library: MeetingLibrary;
const url = "lechuza-media://meeting/2026-10-22-1405?v=1";

function get(range?: string): Promise<Response> {
  return handleMediaRequest(library, new Request(url, range ? { headers: { range } } : {}));
}

beforeAll(async () => {
  root = await fs.mkdtemp(path.join(os.tmpdir(), "lechuza-media-"));
  library = new MeetingLibrary(root);
  await fs.mkdir(path.join(root, "2026-10-22-1405"));
  await fs.writeFile(path.join(root, "2026-10-22-1405", "meeting.m4a"), "0123456789");
});

afterAll(async () => {
  await fs.rm(root, { recursive: true, force: true });
});

// <audio> seeks with byte-range requests; without 206s it can only play from the start.
describe("handleMediaRequest", () => {
  test("serves the whole mix and says it accepts ranges", async () => {
    const response = await get();
    expect(response.status).toBe(200);
    expect(response.headers.get("accept-ranges")).toBe("bytes");
    expect(response.headers.get("content-type")).toBe("audio/mp4");
    expect(response.headers.get("content-length")).toBe("10");
    expect(await response.text()).toBe("0123456789");
  });

  test("serves a byte range for seeking", async () => {
    const response = await get("bytes=2-5");
    expect(response.status).toBe(206);
    expect(response.headers.get("content-range")).toBe("bytes 2-5/10");
    expect(response.headers.get("content-length")).toBe("4");
    expect(await response.text()).toBe("2345");
  });

  test("serves open-ended and suffix ranges, clamped to the file", async () => {
    expect(await (await get("bytes=7-")).text()).toBe("789");
    expect(await (await get("bytes=-3")).text()).toBe("789");
    const clamped = await get("bytes=8-500");
    expect(clamped.headers.get("content-range")).toBe("bytes 8-9/10");
    expect(await clamped.text()).toBe("89");
  });

  test("answers 416 for a range past the end", async () => {
    const response = await get("bytes=10-");
    expect(response.status).toBe(416);
    expect(response.headers.get("content-range")).toBe("bytes */10");
  });

  test("answers 404 for a meeting without a mix, or outside the folder", async () => {
    expect((await handleMediaRequest(library, new Request("lechuza-media://meeting/2026-10-23-0900"))).status).toBe(404);
    expect((await handleMediaRequest(library, new Request("lechuza-media://meeting/..%2F..%2Fetc"))).status).toBe(404);
  });

  test("answers 404 for a symlink that leads out of the meetings folder", async () => {
    const outside = await fs.mkdtemp(path.join(os.tmpdir(), "lechuza-outside-"));
    await fs.writeFile(path.join(outside, "meeting.m4a"), "secret");
    await fs.mkdir(path.join(root, "2026-10-23-0900"));
    await fs.symlink(path.join(outside, "meeting.m4a"), path.join(root, "2026-10-23-0900", "meeting.m4a"));
    await fs.symlink(outside, path.join(root, "2026-10-23-1000"));
    try {
      expect((await handleMediaRequest(library, new Request("lechuza-media://meeting/2026-10-23-0900"))).status).toBe(404);
      expect((await handleMediaRequest(library, new Request("lechuza-media://meeting/2026-10-23-1000"))).status).toBe(404);
    } finally {
      await fs.rm(outside, { recursive: true, force: true });
    }
  });
});
