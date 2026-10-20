# SPDX-License-Identifier: GPL-2.0-only
#
# Watches the ROG Xbox Ally X20's ASUS "N-KEY" HID interface for the Quick Access
# button. The X20 reports it as vendor code 0xa0 in report 0x5a; the original Ally and
# Ally X use 0xa6, which the kernel's hid-asus maps to KEY_F16. hid-asus has no mapping
# for 0xa0, so the press never becomes an input event and Steam never sees it.
#
# hidraw delivers every report to every reader regardless of which kernel driver owns
# the device, so reading it here doesn't take anything away from the system.

import asyncio
import glob
import os
import time

VENDOR = "00000B05"
REPORT_ID = 0x5A
# Vendor descriptor markers of the N-KEY interface: Usage Page 0xff31, Report ID 0x5a.
DESCRIPTOR_MARKERS = (b"\x06\x31\xff", b"\x85\x5a")
DEBOUNCE_S = 0.25
RESCAN_S = 5.0


def is_x20() -> bool:
    try:
        with open("/sys/class/dmi/id/product_name") as f:
            return "RC74XA" in f.read()
    except OSError:
        return False


def find_nkey_hidraw(sysfs: str = "/sys/class/hidraw", devdir: str = "/dev") -> list[str]:
    """Return /dev/hidrawN paths for ASUS N-KEY vendor interfaces."""
    found = []
    for node in sorted(glob.glob(os.path.join(sysfs, "hidraw*"))):
        dev = os.path.join(node, "device")
        try:
            with open(os.path.join(dev, "uevent")) as f:
                uevent = f.read()
            with open(os.path.join(dev, "report_descriptor"), "rb") as f:
                desc = f.read()
        except OSError:
            continue
        hid_id = next((l.split("=", 1)[1] for l in uevent.splitlines() if l.startswith("HID_ID=")), "")
        if VENDOR not in hid_id.upper():
            continue
        if all(m in desc for m in DESCRIPTOR_MARKERS):
            found.append(os.path.join(devdir, os.path.basename(node)))
    return found


class QamWatcher:
    """Calls on_press() when the Quick Access button is pressed."""

    def __init__(self, on_press, log, codes=(0xA0,), sysfs="/sys/class/hidraw", devdir="/dev"):
        self.on_press = on_press
        self.log = log
        self.codes = set(codes)
        self.sysfs = sysfs
        self.devdir = devdir
        self.fds: dict[int, str] = {}
        self.last_press = 0.0
        self.task = None
        self.presses = 0

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
        self._close_all()

    def _close_all(self):
        loop = asyncio.get_event_loop()
        for fd in list(self.fds):
            try:
                loop.remove_reader(fd)
            except Exception:
                pass
            try:
                os.close(fd)
            except OSError:
                pass
        self.fds.clear()

    def _open_new(self):
        loop = asyncio.get_event_loop()
        open_paths = set(self.fds.values())
        for path in find_nkey_hidraw(self.sysfs, self.devdir):
            if path in open_paths:
                continue
            try:
                fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
            except OSError as e:
                self.log(f"cannot open {path}: {e}")
                continue
            self.fds[fd] = path
            loop.add_reader(fd, self._on_readable, fd)
            self.log(f"watching {path} for the Quick Access button")

    def _drop(self, fd):
        path = self.fds.pop(fd, "?")
        try:
            asyncio.get_event_loop().remove_reader(fd)
        except Exception:
            pass
        try:
            os.close(fd)
        except OSError:
            pass
        self.log(f"lost {path}; will look for it again")

    def _on_readable(self, fd):
        while True:
            try:
                data = os.read(fd, 64)
            except BlockingIOError:
                return
            except OSError:
                # Device went away (suspend, USB reset). _run() reopens it.
                self._drop(fd)
                return
            if not data:
                self._drop(fd)
                return
            self.handle_report(data)

    def handle_report(self, data: bytes) -> bool:
        if len(data) < 2 or data[0] != REPORT_ID or data[1] not in self.codes:
            return False
        now = time.monotonic()
        if now - self.last_press < DEBOUNCE_S:
            return False
        self.last_press = now
        self.presses += 1
        self.on_press()
        return True

    async def _run(self):
        try:
            while True:
                self._open_new()
                await asyncio.sleep(RESCAN_S)
        finally:
            self._close_all()
