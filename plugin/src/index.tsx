// SPDX-License-Identifier: GPL-2.0-only
import {
  ButtonItem,
  ConfirmModal,
  Field,
  Navigation,
  PanelSection,
  PanelSectionRow,
  Router,
  Spinner,
  ToggleField,
  showModal,
  staticClasses,
} from "@decky/ui";
import {
  addEventListener,
  callable,
  definePlugin,
  removeEventListener,
  toaster,
  useQuickAccessVisible,
} from "@decky/api";
import { useCallback, useEffect, useState } from "react";
import { FaVolumeUp } from "react-icons/fa";

type Status = Record<string, string>;
type Job = { kind: string; running: boolean; ok: boolean | null; step: string; log: string[] };
type Settings = { auto_apply: boolean; qam_button: boolean; wake_fix: boolean };
type Qam = { supported: boolean; active: boolean; devices: string[]; presses: number };
type Wake = { supported: boolean; active: boolean; wakes: number; reopened: number };
type Snapshot = { status: Status; job: Job; settings: Settings; qam: Qam; wake: Wake };
type Notice = { title?: string; body?: string; state?: string };

const getStatus = callable<[], Snapshot>("get_status");
const getJob = callable<[], Job>("get_job");
const start = callable<[kind: string], boolean>("start");
const setAutoApply = callable<[enabled: boolean], Settings>("set_auto_apply");
const startupNotice = callable<[], Notice>("startup_notice");
const reboot = callable<[], void>("reboot");
const setQamButton = callable<[enabled: boolean], { settings: Settings; qam: Qam }>("set_qam_button");
const setWakeFix = callable<[enabled: boolean], { settings: Settings; wake: Wake }>("set_wake_fix");

// ESideMenu.QuickAccess in Steam's menu store.
const QUICK_ACCESS = 2;

// Open the Quick Access menu, or close it if it is already open (like the real button).
function toggleQuickAccess() {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const menus = (Router as any)?.WindowStore?.GamepadUIMainWindowInstance?.MenuStore;
  if (menus?.ToggleSideMenu) {
    menus.ToggleSideMenu(QUICK_ACCESS);
  } else if (menus?.IsSideMenuVisible?.(QUICK_ACCESS)) {
    Navigation.CloseSideMenus();
  } else {
    Navigation.OpenQuickAccessMenu();
  }
}

// Headline per state from "ally-audio-fix.sh check".
const HEADLINE: Record<string, string> = {
  ok: "Speakers working",
  needs_reboot: "Reboot needed",
  needs_install: "Fix not applied",
  needs_build: "Fix needs a rebuild",
  acpi_stale: "Fix out of date",
  fixed_upstream: "Fix no longer needed",
  broken: "Speakers not working",
  unsupported: "Not an Ally X20",
  kernel_too_old: "Needs SteamOS Beta",
};

// How each component's state reads in the details list.
const COMPONENT: Record<string, Record<string, string>> = {
  acpi: {
    override_active: "Fixed (override active)",
    override_pending: "Fixed after reboot",
    override_ignored: "Override ignored by kernel",
    needed: "Needs fixing",
    not_needed: "Not needed",
    stale: "Built for an older BIOS",
    unknown: "Unknown",
  },
  module: {
    loaded: "Fixed (loaded)",
    installed: "Installed, not loaded",
    available: "Ready to install",
    missing: "Needs building for this kernel",
    not_needed: "Not needed (kernel has it)",
    kernel_too_old: "Needs SteamOS Beta",
  },
  firmware: { installed: "Installed", system: "Provided by SteamOS", missing: "Missing" },
  ucm: { overlay: "Installed", system: "Provided by SteamOS", missing: "Missing" },
};

function confirm(title: string, description: string, ok: string, onOK: () => void) {
  showModal(
    <ConfirmModal strTitle={title} strDescription={description} strOKButtonText={ok} onOK={onOK} />,
  );
}

function Content() {
  const visible = useQuickAccessVisible();
  const [snap, setSnap] = useState<Snapshot | null>(null);
  const [job, setJob] = useState<Job | null>(null);
  const [showLog, setShowLog] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    // Don't spin forever if the backend errors out or never answers.
    const timeout = new Promise<never>((_, reject) =>
      setTimeout(() => reject(new Error("The plugin backend did not respond within 30 seconds.")), 30000),
    );
    try {
      const s = await Promise.race([getStatus(), timeout]);
      setSnap(s);
      setJob(s.job);
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  }, []);

  useEffect(() => {
    if (visible) refresh();
  }, [visible, refresh]);

  // While a job runs and the panel is open, follow its progress.
  useEffect(() => {
    if (!visible || !job?.running) return;
    const timer = setInterval(async () => {
      const j = await getJob();
      setJob(j);
      if (!j.running) refresh();
    }, 1000);
    return () => clearInterval(timer);
  }, [visible, job?.running, refresh]);

  const run = async (kind: string) => {
    if (await start(kind)) {
      setJob({ kind, running: true, ok: null, step: "Starting…", log: [] });
      setShowLog(true);
    }
  };

  if (!snap) {
    return (
      <PanelSection>
        {error ? (
          <>
            <PanelSectionRow>
              <Field label="Could not load status" description={error} bottomSeparator="none" />
            </PanelSectionRow>
            <PanelSectionRow>
              <Field
                label="Logs"
                description="In Desktop Mode: ls ~/homebrew/logs/ and look in the folder for this plugin."
                bottomSeparator="none"
              />
            </PanelSectionRow>
            <PanelSectionRow>
              <ButtonItem layout="below" onClick={() => { setError(null); refresh(); }}>
                Try again
              </ButtonItem>
            </PanelSectionRow>
          </>
        ) : (
          <PanelSectionRow>
            <Spinner style={{ height: "32px" }} />
          </PanelSectionRow>
        )}
      </PanelSection>
    );
  }

  const st = snap.status;
  const state = st.state ?? "broken";
  const busy = !!job?.running;
  const lastLines = (job?.log ?? []).slice(-12);

  const primary = (() => {
    switch (state) {
      case "needs_install":
        return { label: "Apply fix", onClick: () => run("apply") };
      case "needs_build":
        return {
          label: "Rebuild and apply fix",
          onClick: () =>
            confirm(
              "Rebuild the fix?",
              "This downloads the kernel headers and builds the speaker layout module for this " +
                "SteamOS version. It needs internet and takes several minutes; you can close this " +
                "menu while it runs.",
              "Rebuild",
              () => run("apply"),
            ),
        };
      case "needs_reboot":
        return { label: "Reboot now", onClick: () => reboot() };
      case "acpi_stale":
        return {
          label: "Remove outdated fix",
          onClick: () =>
            confirm(
              "Remove the outdated fix?",
              "Your BIOS was updated after the fix was made, so it has to be redone. After the " +
                "reboot, open this menu again and choose Apply fix.",
              "Remove",
              () => run("uninstall"),
            ),
        };
      case "fixed_upstream":
        return { label: "Remove fix", onClick: () => run("uninstall") };
      case "broken":
        return { label: "Try applying again", onClick: () => run("apply") };
      default:
        return null;
    }
  })();

  return (
    <>
      <PanelSection title="Speakers">
        <PanelSectionRow>
          <Field label={HEADLINE[state] ?? state} description={st.message} bottomSeparator="none" />
        </PanelSectionRow>
        {busy && (
          <PanelSectionRow>
            <Field label={job?.step || "Working…"} icon={<Spinner style={{ height: "20px" }} />}
              bottomSeparator="none" />
          </PanelSectionRow>
        )}
        {primary && (
          <PanelSectionRow>
            <ButtonItem layout="below" disabled={busy} onClick={primary.onClick}>
              {primary.label}
            </ButtonItem>
          </PanelSectionRow>
        )}
        {!busy && job?.kind && job.ok === false && (
          <PanelSectionRow>
            <Field label="Last action failed" description="See the log below." bottomSeparator="none" />
          </PanelSectionRow>
        )}
      </PanelSection>

      {state !== "unsupported" && (
        <PanelSection title="Details">
          <PanelSectionRow>
            <Field label="BIOS audio flag">{COMPONENT.acpi[st.acpi] ?? st.acpi}</Field>
          </PanelSectionRow>
          <PanelSectionRow>
            <Field label="Speaker layout">{COMPONENT.module[st.module] ?? st.module}</Field>
          </PanelSectionRow>
          <PanelSectionRow>
            <Field label="Amp tuning">{COMPONENT.firmware[st.firmware] ?? st.firmware}</Field>
          </PanelSectionRow>
          <PanelSectionRow>
            <Field label="Audio profile">{COMPONENT.ucm[st.ucm] ?? st.ucm}</Field>
          </PanelSectionRow>
          <PanelSectionRow>
            <Field label="Kernel" description={st.kernel} bottomSeparator="none" />
          </PanelSectionRow>
          <PanelSectionRow>
            <Field label="BIOS" description={st.bios} />
          </PanelSectionRow>
        </PanelSection>
      )}

      <PanelSection title="Settings">
        {snap.qam.supported && (
          <PanelSectionRow>
            <ToggleField
              label="Quick Access button"
              description={
                !snap.settings.qam_button
                  ? "Off. Use Xbox + A to open this menu."
                  : snap.qam.devices.length
                    ? `Working (${snap.qam.presses} presses since boot).`
                    : "On, but the button's HID interface was not found yet."
              }
              checked={snap.settings.qam_button}
              onChange={async (v) => {
                const r = await setQamButton(v);
                setSnap({ ...snap, settings: r.settings, qam: r.qam });
              }}
            />
          </PanelSectionRow>
        )}
        {snap.wake.supported && (
          <PanelSectionRow>
            <ToggleField
              label="Fix sound after sleep"
              description={
                snap.settings.wake_fix
                  ? `Reopens the speakers right after waking (${snap.wake.reopened} times since boot).`
                  : "Off. After waking, the speakers can stay silent for 30 seconds or more."
              }
              checked={snap.settings.wake_fix}
              onChange={async (v) => {
                const r = await setWakeFix(v);
                setSnap({ ...snap, settings: r.settings, wake: r.wake });
              }}
            />
          </PanelSectionRow>
        )}
        <PanelSectionRow>
          <ToggleField
            label="Re-apply after updates"
            description="When a SteamOS update undoes the fix and no rebuild is needed, re-apply it at boot. You still reboot once."
            checked={snap.settings.auto_apply}
            onChange={async (v) => setSnap({ ...snap, settings: await setAutoApply(v) })}
          />
        </PanelSectionRow>
      </PanelSection>

      <PanelSection title="More">
        <PanelSectionRow>
          <ButtonItem layout="below" disabled={busy} onClick={refresh}>
            Refresh
          </ButtonItem>
        </PanelSectionRow>
        {(job?.log?.length ?? 0) > 0 && (
          <PanelSectionRow>
            <ButtonItem layout="below" onClick={() => setShowLog(!showLog)}>
              {showLog ? "Hide log" : "Show log"}
            </ButtonItem>
          </PanelSectionRow>
        )}
        {showLog && lastLines.length > 0 && (
          <PanelSectionRow>
            <div style={{ fontFamily: "monospace", fontSize: "11px", whiteSpace: "pre-wrap",
              wordBreak: "break-all", opacity: 0.8 }}>
              {lastLines.join("\n")}
            </div>
          </PanelSectionRow>
        )}
        {!["unsupported", "fixed_upstream", "kernel_too_old"].includes(state) && (
          <PanelSectionRow>
            <ButtonItem
              layout="below"
              disabled={busy}
              onClick={() =>
                confirm(
                  "Remove the speaker fix?",
                  "This undoes every change the fix made to this SteamOS slot. The speakers stop " +
                    "working after the next reboot.",
                  "Remove",
                  () => run("uninstall"),
                )
              }
            >
              Remove fix
            </ButtonItem>
          </PanelSectionRow>
        )}
      </PanelSection>
    </>
  );
}

export default definePlugin(() => {
  // Finished jobs (including an automatic re-apply at boot) report back with a toast.
  const onJobDone = addEventListener<[kind: string, ok: boolean, state: string, message: string]>(
    "job_done",
    (kind, ok, state, message) => {
      const what = kind === "uninstall" ? "Speaker fix removed" : "Speaker fix applied";
      toaster.toast({
        title: ok ? what : "Speaker fix: action failed",
        body: ok && state === "needs_reboot" ? "Reboot to finish." : message,
      });
    },
  );

  // The backend saw the X20's Quick Access button.
  const onQamButton = addEventListener<[]>("qam_button", toggleQuickAccess);

  // Once per boot, say so if the fix needs attention (typically after a SteamOS update).
  const noticeTimer = setTimeout(async () => {
    const n = await startupNotice();
    if (n.title) toaster.toast({ title: n.title, body: n.body ?? "", duration: 8000 });
  }, 15000);

  return {
    name: "X20 Fixes",
    titleView: <div className={staticClasses.Title}>X20 Fixes</div>,
    content: <Content />,
    icon: <FaVolumeUp />,
    onDismount() {
      clearTimeout(noticeTimer);
      removeEventListener("job_done", onJobDone);
      removeEventListener("qam_button", onQamButton);
    },
  };
});
