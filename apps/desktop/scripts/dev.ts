// `bun run dev`: a debug build of lechuza-engine, a one-shot bundle of main +
// preload, Vite for the renderer, then Electron pointed at both. Restart to
// pick up main or engine changes; renderer changes hot-reload. Extra
// arguments go to Electron, e.g. `bun run dev --remote-debugging-port=9333`.
import { spawn, spawnSync } from "node:child_process";
import * as path from "node:path";

import electronPath from "electron";

const root = path.resolve(import.meta.dir, "../../..");
const desktop = path.join(root, "apps/desktop");
const DEV_URL = "http://localhost:5792";

const swift = spawnSync("swift", ["build", "--package-path", "engine", "--product", "lechuza-engine"], {
  cwd: root,
  stdio: "inherit",
});
if (swift.status !== 0) process.exit(swift.status ?? 1);

for (const entry of ["main", "preload"]) {
  const result = await Bun.build({
    entrypoints: [path.join(desktop, `src/${entry}.ts`)],
    outdir: path.join(desktop, "dist-electron"),
    naming: `${entry}.cjs`,
    target: "node",
    format: "cjs",
    external: ["electron"],
  });
  if (!result.success) {
    console.error(result.logs.join("\n"));
    process.exit(1);
  }
}

const vite = spawn("bun", ["run", "dev"], { cwd: path.join(root, "apps/web"), stdio: "inherit" });
for (let attempt = 0; attempt < 100; attempt++) {
  if (await fetch(DEV_URL).then((r) => r.ok, () => false)) break;
  await Bun.sleep(100);
}

const electron = spawn(String(electronPath), [desktop, ...process.argv.slice(2)], {
  stdio: "inherit",
  env: {
    ...process.env,
    LECHUZA_DEV_URL: DEV_URL,
    LECHUZA_ENGINE: path.join(root, "engine/.build/debug/lechuza-engine"),
  },
});
electron.on("exit", (code) => {
  vite.kill();
  process.exit(code ?? 0);
});
process.on("SIGINT", () => electron.kill());
