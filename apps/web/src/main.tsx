import { StrictMode, type ComponentType } from "react";
import { createRoot } from "react-dom/client";

import type { Surface } from "@lechuza/contracts";

import "./index.css";
import { Meetings } from "./surfaces/Meetings";

// Each Electron window loads this bundle with `#/<surface>`.
const SURFACES: Record<Surface, ComponentType> = {
  meetings: Meetings,
};

function isSurface(value: string): value is Surface {
  return Object.hasOwn(SURFACES, value);
}

const requested = window.location.hash.replace(/^#\/?/, "").split("/")[0] ?? "";
const Root = SURFACES[isSurface(requested) ? requested : "meetings"];
const container = document.getElementById("root");
if (container) {
  createRoot(container).render(
    <StrictMode>
      <Root />
    </StrictMode>,
  );
}
