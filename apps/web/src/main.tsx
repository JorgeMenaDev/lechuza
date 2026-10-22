import { StrictMode, type ComponentType } from "react";
import { createRoot } from "react-dom/client";

import type { Surface } from "@lechuza/contracts";

import "./index.css";
import { FlowBar } from "./surfaces/FlowBar";
import { Main } from "./surfaces/Main";

// Each Electron window loads this bundle with `#/<surface>`.
const SURFACES: Record<Surface, ComponentType> = {
  main: Main,
  "flow-bar": FlowBar,
};

function isSurface(value: string): value is Surface {
  return Object.hasOwn(SURFACES, value);
}

const requested = window.location.hash.replace(/^#\/?/, "").split("/")[0] ?? "";
const surface: Surface = isSurface(requested) ? requested : "main";
// Set before the first paint: the Flow bar's window must be transparent even
// while its state hasn't arrived (on first launch it waits for macOS to grant
// Documents).
document.documentElement.dataset.surface = surface;
const Root = SURFACES[surface];
const container = document.getElementById("root");
if (container) {
  createRoot(container).render(
    <StrictMode>
      <Root />
    </StrictMode>,
  );
}
