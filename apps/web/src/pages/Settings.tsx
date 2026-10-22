import {
  AudioLines,
  Check,
  ChevronDown,
  HardDrive,
  Info,
  Mic,
  Monitor,
  Moon,
  ShieldCheck,
  SlidersHorizontal,
  Sun,
  type LucideIcon,
} from "lucide-react";
import { useEffect, useState, type ReactNode } from "react";

import type { AppState, ExternalPage, ModelStatus, Speaker, Theme } from "@lechuza/contracts";

import owl from "../../../../assets/icon.svg";
import { lechuza } from "../bridge";

// Settings, a dialog over the main window. Only controls with behaviour are
// live; the rest of each section says how Lechuza works.

type SectionId = "general" | "audio" | "transcription" | "storage" | "permissions" | "about";

const SECTIONS: ReadonlyArray<{ readonly id: SectionId; readonly label: string; readonly icon: LucideIcon }> = [
  { id: "general", label: "General", icon: SlidersHorizontal },
  { id: "audio", label: "Audio", icon: Mic },
  { id: "transcription", label: "Transcription", icon: AudioLines },
  { id: "storage", label: "Storage", icon: HardDrive },
  { id: "permissions", label: "Permissions", icon: ShieldCheck },
  { id: "about", label: "About", icon: Info },
];

export function Settings({ state, onClose }: { state: AppState; onClose: () => void }) {
  const [section, setSection] = useState<SectionId>("general");
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => event.key === "Escape" && onClose();
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);
  const current = SECTIONS.find((item) => item.id === section) ?? SECTIONS[0];

  return (
    <div className="scrim" onMouseDown={(event) => event.target === event.currentTarget && onClose()}>
      <div className="settings" role="dialog" aria-modal="true" aria-label="Settings">
        <nav className="settings-rail">
          <p className="rail-label">Settings</p>
          <ul className="rail-list">
            {SECTIONS.map((item) => (
              <li key={item.id}>
                <button
                  className="rail-item"
                  aria-current={item.id === section ? "page" : undefined}
                  onClick={() => setSection(item.id)}
                >
                  <item.icon /> {item.label}
                </button>
              </li>
            ))}
          </ul>
          <p className="rail-version">Lechuza v{state.info.version}</p>
        </nav>
        <section className="settings-content">
          <h2 className="settings-title">{current?.label}</h2>
          <SectionBody section={section} state={state} />
        </section>
      </div>
    </div>
  );
}

function SectionBody({ section, state }: { section: SectionId; state: AppState }) {
  switch (section) {
    case "general":
      return <General theme={state.settings.theme} />;
    case "audio":
      return <Audio />;
    case "transcription":
      return <Transcription state={state} />;
    case "storage":
      return <Storage state={state} />;
    case "permissions":
      return <Permissions />;
    case "about":
      return <About version={state.info.version} />;
  }
}

function Card({ children }: { children: ReactNode }) {
  return <div className="settings-card">{children}</div>;
}

function Row(props: { label: string; children?: ReactNode; control?: ReactNode }) {
  return (
    <div className="settings-row">
      <div className="settings-row-text">
        <p className="settings-row-label">{props.label}</p>
        {props.children && <p className="settings-row-description">{props.children}</p>}
      </div>
      {props.control && <div className="settings-control">{props.control}</div>}
    </div>
  );
}

// A track's name, coloured as in transcripts.
function Track({ speaker }: { speaker: Speaker }) {
  return (
    <span className="speaker" data-speaker={speaker}>
      {speaker}
    </span>
  );
}

function OpenButton({ page, children }: { page: ExternalPage; children: ReactNode }) {
  return (
    <button className="btn btn-secondary" onClick={() => void lechuza.openExternal(page)}>
      {children}
    </button>
  );
}

const THEMES: ReadonlyArray<{ readonly value: Theme; readonly label: string; readonly icon: LucideIcon }> = [
  { value: "system", label: "System", icon: Monitor },
  { value: "light", label: "Light", icon: Sun },
  { value: "dark", label: "Dark", icon: Moon },
];

function General({ theme }: { theme: Theme }) {
  const ThemeIcon = THEMES.find((item) => item.value === theme)?.icon ?? Monitor;
  return (
    <Card>
      <Row
        label="Theme"
        control={
          <label className="select">
            <ThemeIcon className="select-icon" />
            <select
              aria-label="Theme"
              value={theme}
              onChange={(event) => {
                const next = THEMES.find((item) => item.value === event.currentTarget.value);
                if (next) void lechuza.setTheme(next.value);
              }}
            >
              {THEMES.map((item) => (
                <option key={item.value} value={item.value}>
                  {item.label}
                </option>
              ))}
            </select>
            <ChevronDown className="select-chevron" />
          </label>
        }
      >
        System follows your Mac's appearance.
      </Row>
      <Row label="Menu bar">
        Lechuza keeps running in the menu bar when you close this window. Quit it from the owl.
      </Row>
    </Card>
  );
}

// The Mac's default input, by name once Chromium can tell.
function useDefaultMicrophone(): string | null {
  const [name, setName] = useState<string | null>(null);
  useEffect(() => {
    void navigator.mediaDevices.enumerateDevices().then((devices) => {
      const input = devices.find((device) => device.kind === "audioinput" && device.deviceId === "default");
      setName(input?.label.replace(/^Default - /, "") || null);
    });
  }, []);
  return name;
}

function Audio() {
  const microphone = useDefaultMicrophone();
  return (
    <Card>
      <Row label="Microphone" control={<OpenButton page="sound-settings">Change</OpenButton>}>
        {microphone ?? "Your Mac's default input"}. Lechuza records the input chosen in System Settings → Sound.
      </Row>
      <Row label="Call audio">
        Everything your Mac plays is recorded as <Track speaker="them" />. Without headphones your microphone hears
        the call too, so some of their words appear under <Track speaker="me" />.
      </Row>
    </Card>
  );
}

function ModelBadge({ model }: { model: ModelStatus }) {
  switch (model.state) {
    case "ready":
      return (
        <span className="model-status" data-state="ready">
          <Check /> Ready
        </span>
      );
    case "downloading":
      return (
        <span className="model-status">
          <progress className="progress" value={model.fraction} />
          {model.phase === "compiling" ? "Preparing" : `${Math.round(model.fraction * 100)}%`}
        </span>
      );
    case "missing":
      return <span className="model-status">Not downloaded</span>;
    case "failed":
      return (
        <span className="model-status" data-state="failed">
          Download failed
        </span>
      );
    case "unknown":
      return <span className="model-status">Checking…</span>;
  }
}

function Transcription({ state }: { state: AppState }) {
  const { model } = state;
  return (
    <Card>
      <Row label="Speech model" control={<ModelBadge model={model} />}>
        {model.state === "failed"
          ? `Parakeet v3 couldn't download: ${model.message} Lechuza tries again with the next transcription.`
          : model.state === "missing"
            ? "Parakeet v3 downloads with your first meeting, about 600 MB, once."
            : "Parakeet v3 runs on this Mac, so audio never leaves it."}
      </Row>
      <Row label="Languages">English, Spanish and 23 other European languages, detected on their own.</Row>
    </Card>
  );
}

function Storage({ state }: { state: AppState }) {
  const count = state.meetings.length;
  return (
    <Card>
      <Row
        label="Meetings folder"
        control={
          <button className="btn btn-secondary" onClick={() => void lechuza.revealMeetingsFolder()}>
            Show in Finder
          </button>
        }
      >
        <span className="path">{state.info.meetingsDir}</span>
      </Row>
      <Row label="Meetings">
        {count === 1 ? "1 meeting" : `${count} meetings`}, each a plain folder with both tracks, the mix and the
        transcript. Deleting a meeting moves its folder to the Trash.
      </Row>
    </Card>
  );
}

function Permissions() {
  return (
    <>
      <p className="settings-intro">
        Lechuza asks the first time it needs each one. If you said no, allow Lechuza in System Settings, then start a
        new meeting.
      </p>
      <Card>
        <Row label="Microphone" control={<OpenButton page="privacy-microphone">Open</OpenButton>}>
          Records you, the <Track speaker="me" /> track.
        </Row>
        <Row label="System Audio Recording" control={<OpenButton page="privacy-system-audio">Open</OpenButton>}>
          Records the call, the <Track speaker="them" /> track.
        </Row>
        <Row label="Documents" control={<OpenButton page="privacy-documents">Open</OpenButton>}>
          Saves meetings in Documents → Lechuza → Meetings.
        </Row>
      </Card>
    </>
  );
}

function About({ version }: { version: string }) {
  return (
    <>
      <div className="about">
        <img className="about-mark" src={owl} alt="" />
        <div>
          <p className="about-name">Lechuza</p>
          <p className="about-version">Version {version}</p>
        </div>
      </div>
      <Card>
        <Row label="Source code" control={<OpenButton page="repository">GitHub</OpenButton>}>
          Open source under the MIT licence.
        </Row>
        <Row label="Credits">
          Capture and transcription code adapted from Quill. Parakeet v3 runs through FluidAudio. Figtree and EB
          Garamond fonts under the SIL Open Font License. Icons by Lucide.
        </Row>
      </Card>
    </>
  );
}
