# SPDX-License-Identifier: GPL-2.0-only
#
# Fixes the X20's speakers going silent after sleep.
#
# On resume, PipeWire tries to recover the open SoundWire PCM in place and fails
# ("hw:amdsoundwire,2p: snd_pcm_avail after recover: Broken pipe"), yet it keeps the
# sink marked RUNNING, so nothing plays until the device happens to be closed and
# reopened, typically 30 s or more later. Suspending and resuming the sink forces that
# reopen at once, so we do it right after every wake.

import asyncio
import time

POLL_S = 1.0
# BOOTTIME keeps counting during suspend and MONOTONIC doesn't, so a jump in their
# difference means the system was asleep.
SLEPT_THRESHOLD_S = 2.0
# Give PipeWire a moment to notice the broken stream before reopening it.
SETTLE_S = 1.5


def sleep_offset() -> float:
    return time.clock_gettime(time.CLOCK_BOOTTIME) - time.clock_gettime(time.CLOCK_MONOTONIC)


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

    def __init__(self, on_wake, log, offset=sleep_offset):
        self.on_wake = on_wake
        self.log = log
        self.offset = offset
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
        last = self.offset()
        while True:
            await asyncio.sleep(POLL_S)
            now = self.offset()
            slept, last = now - last, now
            if slept < SLEPT_THRESHOLD_S:
                continue
            self.wakes += 1
            self.log(f"woke after {slept:.0f} s asleep")
            await asyncio.sleep(SETTLE_S)
            try:
                await self.on_wake()
            except Exception as e:  # never let one failure stop the watcher
                self.log(f"after-wake fix failed: {e}")
