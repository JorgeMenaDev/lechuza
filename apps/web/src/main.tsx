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
const Root = SURFACES[isSurface(requested) ? requested : "main"];
const container = document.getElementById("root");
if (container) {
  createRoot(container).render(
    <StrictMode>
      <Root />
    </StrictMode>,
  );
}
