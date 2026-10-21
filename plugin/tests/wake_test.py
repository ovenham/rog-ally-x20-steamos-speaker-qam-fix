# SPDX-License-Identifier: GPL-2.0-only
#
# Tests the after-wake speaker fix: py_modules/wake_fix.py and the backend code that
# runs it. Needs no hardware and no root: python3 tests/wake_test.py
import asyncio
import logging
import os
import sys
import tempfile
import types

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "py_modules"))
import wake_fix  # noqa: E402

# `pactl list short sinks` on an X20 whose speakers were silent after waking.
X20_SINKS = """\
980\talsa_output.pci-0000_64_00.5-platform-amd_sdw.HiFi__Speaker__sink\tPipeWire\ts16le 2ch 48000Hz\tRUNNING
981\talsa_output.pci-0000_64_00.5-platform-amd_sdw.HiFi__Headphones__sink\tPipeWire\ts16le 2ch 48000Hz\tSUSPENDED
1250\talsa_output.pci-0000_64_00.1.hdmi-stereo\tPipeWire\ts32le 2ch 48000Hz\tSUSPENDED
1264\talsa_output.usb-THX_Ltd._THX_Onyx_USB_Amplifier_0-00.analog-stereo\tPipeWire\ts32le 2ch 48000Hz\tRUNNING
"""
SPEAKER = "alsa_output.pci-0000_64_00.5-platform-amd_sdw.HiFi__Speaker__sink"
HEADPHONES = "alsa_output.pci-0000_64_00.5-platform-amd_sdw.HiFi__Headphones__sink"

failures = 0


def check(cond, what):
    global failures
    print(("  ok   " if cond else "  FAIL ") + what)
    failures += 0 if cond else 1


# --- which sinks get reopened -------------------------------------------------------

check(wake_fix.sinks_to_reopen(X20_SINKS) == [SPEAKER],
      "reopens the running speaker sink only (not HDMI, USB, or suspended sinks)")
check(wake_fix.sinks_to_reopen(X20_SINKS.replace("SUSPENDED", "IDLE", 1)) == [SPEAKER, HEADPHONES],
      "also reopens an idle-but-open SoundWire sink")
check(wake_fix.sinks_to_reopen("") == [], "no sinks, nothing to do")


# --- wake detection -------------------------------------------------------------------

async def detection():
    wake_fix.POLL_S = 0.01
    wake_fix.SETTLE_S = 0
    offset = [100.0]
    calls, logs = [], []

    async def on_wake():
        calls.append(offset[0])

    # Without the kernel's sleep counter: the clock offset alone.
    w = wake_fix.WakeWatcher(on_wake, logs.append, offset=lambda: offset[0], count=lambda: None)
    w.start()
    await asyncio.sleep(0.05)
    check(calls == [], "no action while awake")
    offset[0] += 0.001        # rounding noise, not a sleep
    await asyncio.sleep(0.05)
    check(calls == [], "tiny offset changes are ignored")
    offset[0] += 0.6          # a short nap: s2idle only counts part of it
    await asyncio.sleep(0.05)
    check(len(calls) == 1 and w.wakes == 1, "a short sleep is caught from the clocks")
    offset[0] += 60           # slept a minute
    await asyncio.sleep(0.05)
    check(len(calls) == 2, "a long sleep is caught from the clocks")
    calls.clear()

    async def boom():
        raise RuntimeError("pactl missing")
    w.on_wake = boom
    offset[0] += 30
    await asyncio.sleep(0.05)
    check(any("failed" in m for m in logs), "a failing fix is logged")
    w.on_wake = on_wake
    offset[0] += 30
    await asyncio.sleep(0.05)
    check(len(calls) == 1, "the watcher keeps working after a failure")
    await w.stop()
    check(w.task is None, "stop ends the watcher")

    # With the kernel's sleep counter: catches a wake even if the clocks didn't move.
    count = [7]
    calls.clear()
    w = wake_fix.WakeWatcher(on_wake, logs.append, offset=lambda: 5.0, count=lambda: count[0])
    w.start()
    await asyncio.sleep(0.05)
    check(calls == [], "counter unchanged: no action")
    count[0] += 1
    await asyncio.sleep(0.05)
    check(len(calls) == 1, "counter went up: the fix runs")
    await asyncio.sleep(0.05)
    check(len(calls) == 1, "and only once per wake")
    check(any("sleep counter: 7" in m for m in logs), "logs that it is watching")
    await w.stop()

asyncio.run(detection())


# --- re-sending the controller mode -------------------------------------------------

drv = tempfile.mkdtemp()
for dev, mode in (("0003:0B05:1B4C.0003", "1\n"), ("0003:0B05:1B4C.0006", None)):
    os.makedirs(os.path.join(drv, dev))
    if mode is not None:
        with open(os.path.join(drv, dev, "gamepad_mode"), "w") as f:
            f.write(mode)
writes = []
_real_open = open


def tracking_open(path, mode="r", *a, **k):
    if "w" in mode and path.endswith("gamepad_mode"):
        writes.append(path)
    return _real_open(path, mode, *a, **k)


import builtins  # noqa: E402
builtins.open = tracking_open
mode_logs = []
n = wake_fix.resend_gamepad_mode(mode_logs.append, driver_dir=drv)
builtins.open = _real_open
check(n == 1 and len(writes) == 1, "writes gamepad_mode on the device that has it")
with open(os.path.join(drv, "0003:0B05:1B4C.0003", "gamepad_mode")) as f:
    check(f.read() == "1", "writes back the same mode it read (no hardcoded value)")
with open(os.path.join(drv, "0003:0B05:1B4C.0003", "gamepad_mode"), "w") as f:
    f.write("2\n")
wake_fix.resend_gamepad_mode(mode_logs.append, driver_dir=drv)
with open(os.path.join(drv, "0003:0B05:1B4C.0003", "gamepad_mode")) as f:
    check(f.read() == "2", "keeps a mode the user chose")
check(wake_fix.resend_gamepad_mode(mode_logs.append, driver_dir=os.path.join(drv, "missing")) == 0,
      "no controller driver: nothing to do")


# --- the backend runs the right commands, as the desktop user --------------------------

work = tempfile.mkdtemp()
decky = types.ModuleType("decky")
decky.DECKY_PLUGIN_DIR = os.path.join(work, "plugin")
decky.DECKY_PLUGIN_SETTINGS_DIR = os.path.join(work, "settings")
decky.DECKY_USER = "root"
decky.DECKY_USER_HOME = os.path.join(work, "home")
decky.logger = logging.getLogger("plugin")


async def emit(*_):
    pass

decky.emit = emit
sys.modules["decky"] = decky
sys.path.insert(0, os.path.join(HERE, ".."))
import main  # noqa: E402


async def backend():
    p = main.Plugin()
    ran = []

    async def fake_run(cmd, env=None, log=True):
        ran.append(cmd)
        return 0, X20_SINKS if "list" in cmd else ""

    p._run = fake_run
    await p._reopen_sinks()
    pactl = [c[c.index("pactl"):] for c in ran]
    check(pactl == [["pactl", "list", "short", "sinks"],
                    ["pactl", "suspend-sink", SPEAKER, "1"],
                    ["pactl", "suspend-sink", SPEAKER, "0"]],
          "runs exactly: list sinks, suspend the speaker, resume it")
    check(all(c[:3] == ["runuser", "-u", "root"] for c in ran), "runs pactl as the desktop user")
    check(all(any(a.startswith("XDG_RUNTIME_DIR=/run/user/") for a in c) for c in ran),
          "passes the user's runtime dir so pactl finds PipeWire")
    check(p.wake_reopened == 1, "counts the reopen")
    check(main.DEFAULT_SETTINGS["wake_fix"] is True, "on by default")

    # After a wake: mode re-sent, sinks reopened, mode re-sent again, counted once.
    order = []
    wake_fix.MODE_RESEND_LATER_S = 0
    main.wake_fix.resend_gamepad_mode = lambda log: order.append("mode") or 1

    async def fake_reopen():
        order.append("sinks")

    p._reopen_sinks = fake_reopen
    await p._after_wake()
    check(order == ["mode", "sinks", "mode"], "after a wake: mode, speakers, then mode again")
    check(p.mode_resent == 1, "counts the controller fix once per wake")
    check(main.DEFAULT_SETTINGS["button_fix"] is True, "button fix on by default")
    order.clear()
    await p.set_button_fix(False)
    await p._after_wake()
    check(order == ["sinks"], "button fix off: only the speakers")
    await p.set_wake_fix(False)
    check(p.wake is None, "both off: the wake watcher stops")

asyncio.run(backend())

print(f"wake fix: {failures} failure(s)")
sys.exit(1 if failures else 0)
