# SPDX-License-Identifier: GPL-2.0-only
#
# Tests py_modules/qam_button.py with fake sysfs entries and a FIFO standing in for
# the hidraw device. Needs no hardware and no root: python3 tests/qam_test.py
import asyncio
import os
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "py_modules"))
import qam_button  # noqa: E402

NKEY_DESCRIPTOR = b"\x06\x31\xff\x09\x76\xa1\x01\x85\x5a\x19\x00\x2a\xff\x00"
KEYBOARD_DESCRIPTOR = b"\x05\x01\x09\x06\xa1\x01"

root = tempfile.mkdtemp()
sysfs, devdir = os.path.join(root, "sys"), os.path.join(root, "dev")
os.makedirs(devdir)
failures = 0


def check(cond, what):
    global failures
    print(("  ok   " if cond else "  FAIL ") + what)
    failures += 0 if cond else 1


def fake_hidraw(name, hid_id, descriptor):
    d = os.path.join(sysfs, name, "device")
    os.makedirs(d)
    with open(os.path.join(d, "uevent"), "w") as f:
        f.write(f"HID_ID={hid_id}\nHID_NAME=fake\n")
    with open(os.path.join(d, "report_descriptor"), "wb") as f:
        f.write(descriptor)


def open_writer(path):
    # Opening a FIFO for writing blocks until a reader exists; use a throwaway reader.
    r = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    w = os.open(path, os.O_WRONLY)
    os.close(r)
    return w


fake_hidraw("hidraw2", "0003:0000045E:00000B12", NKEY_DESCRIPTOR)       # not ASUS
fake_hidraw("hidraw4", "0003:00000B05:00001B4C", KEYBOARD_DESCRIPTOR)   # ASUS keyboard
fake_hidraw("hidraw5", "0003:00000B05:00001B4C", NKEY_DESCRIPTOR)       # ASUS N-KEY

check(qam_button.find_nkey_hidraw(sysfs, devdir) == [os.path.join(devdir, "hidraw5")],
      "finds only the ASUS N-KEY interface")


async def main():
    qam_button.RESCAN_S = 0.05
    qam_button.DEBOUNCE_S = 0.1
    fifo = os.path.join(devdir, "hidraw5")
    os.mkfifo(fifo)
    presses, logs = [], []
    watcher = qam_button.QamWatcher(lambda: presses.append(1), logs.append, sysfs=sysfs, devdir=devdir)

    w = open_writer(fifo)

    def send(report):
        os.write(w, report.ljust(64, b"\0"))

    watcher.start()
    await asyncio.sleep(0.1)
    check(len(watcher.fds) == 1, "opens the device")

    send(b"\x5a\xa0")
    await asyncio.sleep(0.05)
    check(len(presses) == 1, "5a a0 is a press")
    send(b"\x5a\xa0")
    await asyncio.sleep(0.05)
    check(len(presses) == 1, "a repeat within the debounce time is ignored")
    await asyncio.sleep(0.1)
    send(b"\x5a\xa0")
    await asyncio.sleep(0.05)
    check(len(presses) == 2, "the next press counts")

    await asyncio.sleep(0.15)
    for report in (b"\x5a\xa6", b"\x5a\x38", b"\x5a\x00", b"\x01\xa0"):
        send(report)
    await asyncio.sleep(0.05)
    check(len(presses) == 2, "other codes, releases and report IDs are ignored")

    os.close(w)
    await asyncio.sleep(0.03)
    check(any("lost" in line for line in logs), "notices the device going away")

    w = open_writer(fifo)  # back, as after resume from sleep
    for _ in range(40):
        await asyncio.sleep(0.05)
        if watcher.fds:
            break
    await asyncio.sleep(0.15)
    send(b"\x5a\xa0")
    await asyncio.sleep(0.05)
    check(len(presses) == 3, "works again after the device comes back")

    await watcher.stop()
    check(not watcher.fds and watcher.task is None, "stop closes everything")
    os.close(w)


asyncio.run(main())
print(f"qam watcher: {failures} failure(s)")
sys.exit(1 if failures else 0)
