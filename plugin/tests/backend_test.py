# SPDX-License-Identifier: GPL-2.0-only
#
# Drives main.py's Plugin against the simulated X20 from speaker-fix/tests.
# Run from the repo root: sudo PLUGIN=plugin speaker-fix/tests/run.sh
#   argv: <plugin source dir> <speaker-fix dir> <command that simulates a reboot>
import asyncio
import logging
import os
import subprocess
import sys
import tempfile
import types

plugin_src, script_repo, reboot_cmd = sys.argv[1:4]
work = tempfile.mkdtemp()
plugin_dir = os.path.join(work, "plugin")
os.makedirs(plugin_dir)
os.symlink(script_repo, os.path.join(plugin_dir, "fix"))
events = []


async def emit(event, *args):
    events.append((event, *args))


decky = types.ModuleType("decky")
decky.DECKY_PLUGIN_DIR = plugin_dir
decky.DECKY_PLUGIN_SETTINGS_DIR = os.path.join(work, "settings")
decky.DECKY_USER = "root"
decky.DECKY_USER_HOME = os.path.join(work, "home")
decky.logger = logging.getLogger("plugin")
decky.emit = emit
sys.modules["decky"] = decky
sys.path.insert(0, plugin_src)
import main  # noqa: E402

# The backend gives the script a clean PATH; here it must still find the fake tools.
main.PATH = os.environ["PATH"]
real_sleep = asyncio.sleep

failures = 0


def check(cond, what):
    global failures
    print(("       ok   " if cond else "       FAIL ") + what)
    failures += 0 if cond else 1


def reboot():
    subprocess.run(reboot_cmd, shell=True, check=True)


async def wait_job(p):
    for _ in range(600):
        j = await p.get_job()
        if not j["running"]:
            return j
        await real_sleep(0.1)
    raise TimeoutError("job did not finish")


async def no_wait(_seconds):
    await real_sleep(0)


async def test():
    p = main.Plugin()
    snap = await p.get_status()
    check(snap["status"]["state"] == "needs_install", "reports needs_install")
    check(snap["settings"]["auto_apply"] is False, "auto-apply is off by default")
    n = await p.startup_notice()
    check(n.get("state") == "needs_install", "startup toast offered")
    check(await p.startup_notice() == {}, "startup toast not repeated in the same boot")

    check(await p.start("apply") is True, "apply starts")
    check(await p.start("apply") is False, "a second job is refused while one runs")
    j = await wait_job(p)
    await real_sleep(0)  # let the job_done event go out
    check(j["ok"] is True, "apply succeeds")
    if not j["ok"]:
        print("\n".join("         | " + line for line in j["log"]))
    check(any("Done. Reboot" in line for line in j["log"]), "job output captured")
    check(bool(events) and events[-1][:4] == ("job_done", "apply", True, "needs_reboot"),
          "job_done event reports reboot needed")
    data = os.path.join(decky.DECKY_USER_HOME, ".local", "share", "ally-audio-fix")
    check(os.path.isdir(data), "data dir created in the user's home")

    reboot()
    p = main.Plugin()
    check((await p.get_status())["status"]["state"] == "ok", "after reboot: working")
    check(await p.startup_notice() == {}, "no toast when everything works")

    # The fix disappears (as after a SteamOS update) with auto-apply on.
    await p.start("uninstall")
    j = await wait_job(p)
    check(j["ok"] is True, "uninstall succeeds")
    check((await p.get_status())["status"]["state"] == "needs_reboot", "uninstall asks for a reboot")
    check((await p.set_auto_apply(True))["auto_apply"] is True, "auto-apply saved")
    reboot()
    p = main.Plugin()
    main.asyncio.sleep = no_wait
    await p._main()
    j = await wait_job(p)
    check(j["kind"] == "apply" and j["ok"] is True, "re-applied automatically at boot")
    check(await p.startup_notice() == {}, "no 'needs fix' toast after auto re-apply")
    main.asyncio.sleep = real_sleep


asyncio.run(test())
sys.exit(1 if failures else 0)
