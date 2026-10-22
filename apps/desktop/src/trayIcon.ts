import { nativeImage, type NativeImage } from "electron";

import { TRAY_GLYPH } from "./trayGlyph.ts";

// The menu bar owl from assets/tray.svg at 1x and 2x, as a macOS template
// image so it follows light and dark menu bars.
export function createTrayIcon(): NativeImage {
  const image = nativeImage.createEmpty();
  for (const scale of [1, 2] as const) {
    const size = 18 * scale;
    const alpha = Buffer.from(TRAY_GLYPH[scale], "base64");
    const pixels = Buffer.alloc(size * size * 4);
    for (let i = 0; i < size * size; i++) {
      pixels.writeUInt32LE((alpha.readUInt8(i) << 24) >>> 0, i * 4); // BGRA, black
    }
    image.addRepresentation({ scaleFactor: scale, width: size, height: size, buffer: pixels });
  }
  image.setTemplateImage(true);
  return image;
}
