// Renders assets/icon.svg into build/icon.icns, the app icon electron-builder packs.
// Run after editing the SVG: bun apps/desktop/scripts/app-icon.ts
import { spawnSync } from "node:child_process";
import * as fs from "node:fs/promises";
import * as os from "node:os";
import path from "node:path";
import { Resvg } from "@resvg/resvg-js";

const root = path.join(import.meta.dir, "../../..");
const output = path.join(import.meta.dir, "../build/icon.icns");

const svg = await Bun.file(path.join(root, "assets/icon.svg")).text();
const iconset = path.join(await fs.mkdtemp(path.join(os.tmpdir(), "lechuza-icon-")), "icon.iconset");
await fs.mkdir(iconset);
// iconutil wants each size at 1x and 2x: icon_16x16.png, icon_16x16@2x.png (32 px), …
for (const size of [16, 32, 128, 256, 512]) {
  for (const scale of [1, 2]) {
    const png = new Resvg(svg, { fitTo: { mode: "width", value: size * scale } }).render().asPng();
    await Bun.write(path.join(iconset, `icon_${size}x${size}${scale === 2 ? "@2x" : ""}.png`), png);
  }
}
const result = spawnSync("iconutil", ["-c", "icns", iconset, "-o", output], { stdio: "inherit" });
await fs.rm(path.dirname(iconset), { recursive: true, force: true });
process.exit(result.status ?? 1);
