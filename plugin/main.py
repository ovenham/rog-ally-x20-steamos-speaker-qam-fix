# SPDX-License-Identifier: GPL-2.0-only
#
# Decky backend for X20 Fixes. It runs as root (plugin.json "root" flag) and drives
# fix/ally-audio-fix.sh (speaker-fix/ in the repo), which does the actual work:
#
#   check      read-only state, as key=value lines
#   install    apply what is still needed for this kernel/slot
#   uninstall  remove everything
#   build      build the layout module for a new kernel (runs as the deck user,
#              because it uses rootless podman)
#
# After a SteamOS update the fix has to be applied again to the new slot. The plugin
# checks at every boot and either tells the user (toast) or, if they opted in, just
# re-applies it.
#
# It also makes the X20's Quick Access button work (py_modules/qam_button.py): the
# backend watches for the press and the frontend opens the menu.

import asyncio
import json
import os
import pwd
import sys

import decky

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "py_modules"))
import qam_button  # noqa: E402

SCRIPT = os.path.join(decky.DECKY_PLUGIN_DIR, "fix", "ally-audio-fix.sh")
SETTINGS_FILE = os.path.join(decky.DECKY_PLUGIN_SETTINGS_DIR, "settings.json")
# Built modules and downloaded firmware live in the user's home, which survives
# SteamOS updates and plugin updates.
DATA_DIR = os.path.join(decky.DECKY_USER_HOME, ".local", "share", "ally-audio-fix")
PATH = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
DEFAULT_SETTINGS = {"auto_apply": False, "notified_boot": "", "qam_button": True}
MAX_LOG_LINES = 400

# States that mean "the user should do something" and the startup toast for each.
NOTICES = {
    "needs_install": ("Speakers need the fix again",
                      "SteamOS was updated. Open X20 Fixes to re-apply it."),
    "needs_build": ("Speakers need the fix again",
                    "SteamOS has a new kernel. Open X20 Fixes to rebuild and re-apply it."),
    "acpi_stale": ("Speaker fix is out of date",
                   "The BIOS was updated. Open X20 Fixes to redo the fix."),
    "fixed_upstream": ("SteamOS supports the speakers now",
                       "The speaker fix is no longer needed and can be removed."),
    "broken": ("Speaker fix did not take effect",
               "Open X20 Fixes for details."),
}


def _boot_id() -> str:
    try:
        with open("/proc/sys/kernel/random/boot_id") as f:
            return f.read().strip()
    except OSError:
        return ""


def _parse_check(text: str) -> dict:
    out = {}
    for line in text.splitlines():
        key, sep, value = line.partition("=")
        if sep:
            out[key.strip()] = value.strip()
    return out


class Plugin:
    def __init__(self):
        self.job = {"kind": "", "running": False, "ok": None, "step": "", "log": []}
        self.task = None
        self.last_status = {}
        self.qam = None

    # --- helpers ----------------------------------------------------------------------

    def _settings(self) -> dict:
        try:
            with open(SETTINGS_FILE) as f:
                return {**DEFAULT_SETTINGS, **json.load(f)}
        except (OSError, ValueError):
            return dict(DEFAULT_SETTINGS)

    def _save_settings(self, settings: dict) -> None:
        os.makedirs(os.path.dirname(SETTINGS_FILE), exist_ok=True)
        tmp = SETTINGS_FILE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(settings, f)
        os.replace(tmp, SETTINGS_FILE)

    def _env(self) -> dict:
        # A clean environment: Decky's own (PyInstaller) LD_LIBRARY_PATH breaks system
        # tools like curl and podman if it leaks into child processes.
        return {"PATH": PATH, "LANG": "C.UTF-8", "HOME": "/root", "ALLY_AUDIO_DATA": DATA_DIR}

    def _user_cmd(self, *args: str) -> list:
        pw = pwd.getpwnam(decky.DECKY_USER)
        runtime = f"/run/user/{pw.pw_uid}"
        return ["runuser", "-u", pw.pw_name, "--", "env", "-i",
                f"PATH={PATH}", "LANG=C.UTF-8", f"HOME={pw.pw_dir}", f"USER={pw.pw_name}",
                f"XDG_RUNTIME_DIR={runtime}", f"DBUS_SESSION_BUS_ADDRESS=unix:path={runtime}/bus",
                f"ALLY_AUDIO_DATA={DATA_DIR}", "/bin/sh", SCRIPT, *args]

    def _prepare_data_dir(self) -> None:
        # Owned by the deck user so the rootless build can write into it.
        pw = pwd.getpwnam(decky.DECKY_USER)
        os.makedirs(DATA_DIR, exist_ok=True)
        for root, dirs, files in os.walk(DATA_DIR):
            for name in [root] + [os.path.join(root, n) for n in dirs + files]:
                try:
                    os.lchown(name, pw.pw_uid, pw.pw_gid)
                except OSError:
                    pass
        # ~/.local and ~/.local/share may have just been created by root, too.
        for d in (os.path.dirname(os.path.dirname(DATA_DIR)), os.path.dirname(DATA_DIR)):
            try:
                st = os.stat(d)
                if st.st_uid == 0:
                    os.chown(d, pw.pw_uid, pw.pw_gid)
            except OSError:
                pass

    def _log(self, line: str) -> None:
        log = self.job["log"]
        log.append(line)
        del log[:-MAX_LOG_LINES]
        decky.logger.info("%s: %s", self.job["kind"] or "fix", line)

    async def _run(self, cmd: list, env: dict | None = None, log: bool = True) -> tuple[int, str]:
        proc = await asyncio.create_subprocess_exec(
            *cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT,
            env=env if env is not None else self._env(), stdin=asyncio.subprocess.DEVNULL)
        out = []
        assert proc.stdout is not None
        async for raw in proc.stdout:
            line = raw.decode(errors="replace").rstrip()
            out.append(line)
            if log:
                self._log(line)
        return await proc.wait(), "\n".join(out)

    async def _check(self) -> dict:
        if not os.path.exists(SCRIPT):
            return {"state": "broken", "message": f"Plugin files are incomplete: {SCRIPT} is missing."}
        try:
            rc, out = await asyncio.wait_for(self._run(["/bin/sh", SCRIPT, "check"], log=False), 60)
        except asyncio.TimeoutError:
            return {"state": "broken", "message": "Checking the speaker state timed out."}
        status = _parse_check(out)
        if rc != 0 or "state" not in status:
            status = {"state": "broken", "message": "Could not check the speaker state.", "detail": out[-2000:]}
        self.last_status = status
        return status

    async def _job_main(self, kind: str) -> None:
        ok = False
        try:
            self._prepare_data_dir()
            if kind == "apply":
                status = await self._check()
                if status.get("state") == "needs_build":
                    self.job["step"] = "Building the layout module for this kernel (several minutes)"
                    rc, _ = await self._run(self._user_cmd("build"))
                    if rc != 0:
                        self._log("Build failed; nothing was changed.")
                        return
                self.job["step"] = "Applying the fix"
                rc, _ = await self._run(["/bin/sh", SCRIPT, "install"])
                ok = rc == 0
            elif kind == "build":
                self.job["step"] = "Building the layout module for this kernel (several minutes)"
                rc, _ = await self._run(self._user_cmd("build"))
                ok = rc == 0
            elif kind == "uninstall":
                self.job["step"] = "Removing the fix"
                rc, _ = await self._run(["/bin/sh", SCRIPT, "uninstall"])
                ok = rc == 0
            else:
                self._log(f"unknown action {kind}")
        except Exception as e:  # keep the plugin alive whatever happens
            decky.logger.exception("job %s failed", kind)
            self._log(f"error: {e}")
        finally:
            try:
                self._prepare_data_dir()
            except Exception:
                pass
            # Re-check before reporting the job done, so the panel and the boot-time
            # notice never see the state from before the job.
            self.job["step"] = "Checking"
            status = await self._check()
            self.job["ok"] = ok
            self.job["step"] = ""
            self.job["running"] = False
            await decky.emit("job_done", kind, ok, status.get("state", ""), status.get("message", ""))

    # --- callable from the frontend -----------------------------------------------------

    async def get_status(self) -> dict:
        status = await self._check()
        return {"status": status, "job": self.job, "settings": self._settings(),
                "qam": self._qam_info()}

    async def get_job(self) -> dict:
        return self.job

    async def start(self, kind: str) -> bool:
        if self.job["running"]:
            return False
        # Mark it running before the task starts, so a second tap can't start another.
        self.job = {"kind": kind, "running": True, "ok": None, "step": "Starting", "log": []}
        self.task = asyncio.get_event_loop().create_task(self._job_main(kind))
        return True

    async def set_auto_apply(self, enabled: bool) -> dict:
        settings = self._settings()
        settings["auto_apply"] = bool(enabled)
        self._save_settings(settings)
        return settings

    async def set_qam_button(self, enabled: bool) -> dict:
        settings = self._settings()
        settings["qam_button"] = bool(enabled)
        self._save_settings(settings)
        if enabled:
            self._start_qam()
        elif self.qam:
            await self.qam.stop()
            self.qam = None
        return {"settings": settings, "qam": self._qam_info()}

    # --- Quick Access button ------------------------------------------------------------

    def _qam_info(self) -> dict:
        return {
            "supported": qam_button.is_x20(),
            "active": self.qam is not None,
            "devices": sorted(self.qam.fds.values()) if self.qam else [],
            "presses": self.qam.presses if self.qam else 0,
        }

    def _start_qam(self) -> None:
        if self.qam or not qam_button.is_x20():
            return
        loop = asyncio.get_event_loop()

        def pressed():
            loop.create_task(decky.emit("qam_button"))

        self.qam = qam_button.QamWatcher(pressed, lambda m: decky.logger.info("qam: %s", m))
        self.qam.start()

    async def startup_notice(self) -> dict:
        """The toast to show once per boot, if the fix needs attention."""
        settings = self._settings()
        boot = _boot_id()
        if settings.get("notified_boot") == boot:
            return {}
        status = self.last_status or await self._check()
        state = status.get("state", "")
        if self.job["running"] or state not in NOTICES:
            return {}
        settings["notified_boot"] = boot
        self._save_settings(settings)
        title, body = NOTICES[state]
        return {"title": title, "body": body, "state": state}

    async def reboot(self) -> None:
        await self._run(["systemctl", "reboot"], log=False)

    # --- Decky lifecycle -----------------------------------------------------------------

    async def _main(self):
        decky.logger.info("X20 Fixes loaded")
        if self._settings().get("qam_button"):
            self._start_qam()
        # Give the audio stack a moment to come up before judging it.
        await asyncio.sleep(10)
        status = await self._check()
        decky.logger.info("state at boot: %s (%s)", status.get("state"), status.get("message"))
        if self._settings().get("auto_apply") and status.get("state") == "needs_install":
            decky.logger.info("re-applying automatically")
            await self.start("apply")

    async def _unload(self):
        if self.qam:
            await self.qam.stop()
            self.qam = None
        if self.task and not self.task.done():
            decky.logger.info("plugin unloading while a job runs; it will be cut short")

    async def _uninstall(self):
        # Removing the plugin does not remove the fix: the speakers keep working.
        # Use "Remove fix" in the plugin first if you want everything gone.
        pass
