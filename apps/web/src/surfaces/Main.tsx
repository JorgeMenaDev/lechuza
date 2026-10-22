import { CircleDot, House, Moon, PanelLeft, Settings as SettingsIcon, Sun, X, type LucideIcon } from "lucide-react";
import { useCallback, useEffect, useState, type ReactNode } from "react";

import { formatClock, type AppState } from "@lechuza/contracts";

import owl from "../../../../assets/icon.svg";
import { lechuza, useAppState, useDarkMode, useNow } from "../bridge";
import { Home } from "../pages/Home";
import { Meeting } from "../pages/Meeting";
import { Meetings } from "../pages/Meetings";
import { Settings } from "../pages/Settings";

// The main window: title bar strip, sidebar, and the rounded page panel.
// Settings opens as a dialog over it.

type Page = { readonly name: "home" } | { readonly name: "meetings" } | { readonly name: "meeting"; readonly id: string };

export function Main() {
  const state = useAppState();
  const [page, setPage] = useState<Page>({ name: "home" });
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [collapsed, setCollapsed] = useState(false);
  const closeSettings = useCallback(() => setSettingsOpen(false), []);
  const recordingId = state?.recording?.id ?? null;
  // A new recording opens itself, with its levels and Stop.
  useEffect(() => {
    if (recordingId) setPage({ name: "meeting", id: recordingId });
  }, [recordingId]);

  if (!state) return null;
  const openMeeting = (id: string) => setPage({ name: "meeting", id });
  const meeting = page.name === "meeting" ? state.meetings.find((item) => item.id === page.id) : undefined;

  return (
    <div className="window" data-sidebar={collapsed ? "collapsed" : "expanded"}>
      <header className="chrome">
        <button
          className="icon-button"
          title={collapsed ? "Show sidebar" : "Hide sidebar"}
          onClick={() => setCollapsed(!collapsed)}
        >
          <PanelLeft />
        </button>
        <ThemeButton />
      </header>
      <nav className="sidebar" aria-label="Lechuza">
        <div className="brand">
          <img className="brand-mark" src={owl} alt="" />
          <span className="brand-name">Lechuza</span>
        </div>
        <ul className="nav">
          <NavItem icon={House} label="Home" current={page.name === "home"} onClick={() => setPage({ name: "home" })} />
          <NavItem
            icon={CircleDot}
            label="Meetings"
            current={page.name !== "home"}
            onClick={() => setPage({ name: "meetings" })}
          >
            <RecordingBadge state={state} />
          </NavItem>
        </ul>
        <ul className="nav sidebar-footer">
          <NavItem icon={SettingsIcon} label="Settings" current={false} onClick={() => setSettingsOpen(true)} />
        </ul>
      </nav>
      <main className="panel">
        <Notices state={state} />
        {page.name === "home" ? (
          <Home state={state} onOpenMeeting={openMeeting} />
        ) : meeting ? (
          <Meeting key={meeting.id} meeting={meeting} state={state} onBack={() => setPage({ name: "meetings" })} />
        ) : (
          <Meetings state={state} onOpenMeeting={openMeeting} />
        )}
      </main>
      {settingsOpen && <Settings state={state} onClose={closeSettings} />}
    </div>
  );
}

function NavItem(props: { icon: LucideIcon; label: string; current: boolean; onClick: () => void; children?: ReactNode }) {
  return (
    <li>
      <button
        className="nav-item"
        title={props.label}
        aria-current={props.current ? "page" : undefined}
        onClick={props.onClick}
      >
        <props.icon />
        <span className="nav-label">{props.label}</span>
        {props.children}
      </button>
    </li>
  );
}

// The elapsed time beside Meetings while one records.
function RecordingBadge({ state }: { state: AppState }) {
  const startedAt = state.recording?.startedAt ?? null;
  const now = useNow(startedAt !== null);
  if (startedAt === null) return null;
  return <span className="nav-badge">{formatClock(now - startedAt)}</span>;
}

// Switches between light and dark, whatever the theme was.
function ThemeButton() {
  const dark = useDarkMode();
  return (
    <button
      className="icon-button"
      title={dark ? "Light mode" : "Dark mode"}
      onClick={() => void lechuza.setTheme(dark ? "light" : "dark")}
    >
      {dark ? <Sun /> : <Moon />}
    </button>
  );
}

function Notices({ state }: { state: AppState }) {
  const { notice, model } = state;
  if (!notice && model.state !== "downloading" && model.state !== "failed") return null;
  return (
    <div className="notices">
      {notice && (
        <div className="notice" data-tone="warning" role="alert">
          <span className="notice-text">{notice}</span>
          <button className="icon-button icon-button-small" title="Dismiss" onClick={() => void lechuza.dismissNotice()}>
            <X />
          </button>
        </div>
      )}
      {model.state === "downloading" && (
        <div className="notice" role="status">
          <span className="notice-text">
            {model.phase === "compiling"
              ? "Preparing the speech model…"
              : `Downloading the speech model (about 600 MB, only once)… ${Math.round(model.fraction * 100)}%`}
          </span>
          <progress className="progress" value={model.fraction} />
        </div>
      )}
      {model.state === "failed" && (
        <div className="notice" data-tone="warning" role="alert">
          <span className="notice-text">
            Couldn't download the speech model: {model.message} Lechuza tries again with the next transcription.
          </span>
        </div>
      )}
    </div>
  );
}
