# SPDX-License-Identifier: GPL-2.0-only
#
# Fixes two things that sometimes go wrong when the X20 wakes from sleep.
#
# Buttons: the controller sometimes comes back in a different mode. The Xbox button
# goes dead and the extra buttons send keyboard keys (Quick Access sends F1, Armoury
# Crate F8), while the driver's gamepad_mode still reads the old value. Writing that
# same value back to gamepad_mode makes the driver re-send it, which restores them.
#
# Speakers:
# On resume, PipeWire tries to recover the open SoundWire PCM in place and fails
# ("hw:amdsoundwire,2p: snd_pcm_avail after recover: Broken pipe"), yet it keeps the
# sink marked RUNNING, so nothing plays until the device happens to be closed and
# reopened, typically 30 s or more later. Suspending and resuming the sink forces that
# reopen at once, so we do it right after every wake.

import asyncio
import glob
import os
import time

POLL_S = 1.0
# The kernel counts successful sleeps; it goes up by one on every wake.
SUSPEND_COUNT = "/sys/power/suspend_stats/success"
# Fallback if that file is missing: BOOTTIME keeps counting during sleep and MONOTONIC
# doesn't, so their difference only ever changes across a sleep. With s2idle the jump
# can be well under a second for a short nap, so the threshold is low.
SLEPT_THRESHOLD_S = 0.25
# Give PipeWire a moment to notice the broken stream before reopening it.
SETTLE_S = 1.5


def sleep_offset() -> float:
    return time.clock_gettime(time.CLOCK_BOOTTIME) - time.clock_gettime(time.CLOCK_MONOTONIC)


def suspend_count() -> int | None:
    try:
        with open(SUSPEND_COUNT) as f:
            return int(f.read().strip())
    except (OSError, ValueError):
        return None


# The ROG Ally controller driver's config interface(s).
ALLY_DRIVER = "/sys/bus/hid/drivers/asus_rog_ally"
# The controller may not be ready right after a wake, so the mode is sent again later.
MODE_RESEND_LATER_S = 3.0


def gamepad_mode_files(driver_dir: str = ALLY_DRIVER) -> list[str]:
    return sorted(glob.glob(os.path.join(driver_dir, "*", "gamepad_mode")))


def resend_gamepad_mode(log, driver_dir: str = ALLY_DRIVER) -> int:
    """Write each controller's current gamepad_mode back to it. Returns how many."""
    done = 0
    for path in gamepad_mode_files(driver_dir):
        try:
            with open(path) as f:
                mode = f.read().strip()
            if not mode:
                continue
            with open(path, "w") as f:
                f.write(mode)
            done += 1
            log(f"re-sent gamepad_mode {mode} to {os.path.basename(os.path.dirname(path))}")
        except OSError as e:
            log(f"could not re-send gamepad_mode via {path}: {e}")
    return done


def sinks_to_reopen(pactl_short_sinks: str) -> list[str]:
    """X20 SoundWire sinks (speakers, headphones) that are open, from
    `pactl list short sinks`. Suspended ones are closed already and reopen fine."""
    names = []
    for line in pactl_short_sinks.splitlines():
        cols = line.split()
        if len(cols) < 2 or "amd_sdw" not in cols[1]:
            continue
        if cols[-1] in ("RUNNING", "IDLE"):
            names.append(cols[1])
    return names


class WakeWatcher:
    """Calls `on_wake` (a coroutine function) after each resume from sleep."""

    def __init__(self, on_wake, log, offset=sleep_offset, count=suspend_count):
        self.on_wake = on_wake
        self.log = log
        self.offset = offset
        self.count = count
        self.task = None
        self.wakes = 0

    def start(self):
        if not self.task:
            self.task = asyncio.get_event_loop().create_task(self._run())

    async def stop(self):
        if self.task:
            self.task.cancel()
            try:
                await self.task
            except (asyncio.CancelledError, Exception):
                pass
            self.task = None

    async def _run(self):
        last_offset, last_count = self.offset(), self.count()
        self.log(f"watching for wakes (sleep counter: {last_count if last_count is not None else 'unavailable'})")
        while True:
            await asyncio.sleep(POLL_S)
            offset, count = self.offset(), self.count()
            slept = offset - last_offset
            counted = count is not None and last_count is not None and count != last_count
            last_offset, last_count = offset, count
            if not counted and slept < SLEPT_THRESHOLD_S:
                continue
            self.wakes += 1
            self.log(f"woke (sleep counter {count}, about {slept:.1f} s asleep)")
            await asyncio.sleep(SETTLE_S)
            try:
                await self.on_wake()
            except Exception as e:  # never let one failure stop the watcher
                self.log(f"after-wake fix failed: {e}")
