#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# x20-buttons.sh - shows what the ROG Xbox Ally X20's extra buttons send under SteamOS.
#
# Lists the ASUS HID interfaces and their drivers, then records 10 seconds of button
# presses: key and gamepad events from /dev/input, and raw 0x5a reports from the ASUS
# "N-KEY" interface (hidraw). Read-only; it changes nothing.
#
# Usage: sudo ./x20-buttons.sh
set -eu

die() { echo "error: $*" >&2; exit 1; }
need_root() { [ "$(id -u)" = 0 ] || die "run with sudo"; }

# HID devices from ASUS (vendor 0b05) on USB: prints "<sysfs name> <product id hex>".
asus_hid_devices() {
	for d in /sys/bus/hid/devices/0003:0B05:*; do
		[ -e "$d" ] || continue
		n=$(basename "$d")
		pid=$(echo "$n" | cut -d: -f3 | cut -d. -f1)
		echo "$n $pid"
	done
}

# The ASUS N-Key vendor interface: usage page 0xff31 and report ID 0x5a.
is_nkey_interface() {
	python3 -I - "/sys/bus/hid/devices/$1/report_descriptor" <<'PY'
import sys
d = open(sys.argv[1], "rb").read()
sys.exit(0 if b"\x06\x31\xff" in d and b"\x85\x5a" in d else 1)
PY
}

driver_of() {
	l=$(readlink "/sys/bus/hid/devices/$1/driver" 2>/dev/null) || { echo none; return; }
	basename "$l"
}

cmd_diagnose() {
	need_root
	echo "== device"
	echo "$(cat /sys/class/dmi/id/product_name 2>/dev/null) / BIOS $(cat /sys/class/dmi/id/bios_version 2>/dev/null) / kernel $(uname -r)"
	echo
	echo "== ASUS USB devices"
	lsusb -d 0b05: 2>/dev/null || echo "(lsusb not available)"
	echo
	echo "== ASUS HID interfaces"
	asus_hid_devices | while read -r n pid; do
		nkey=no
		is_nkey_interface "$n" && nkey=yes
		echo "$n  pid=$pid  driver=$(driver_of "$n")  nkey-interface=$nkey"
	done
	echo
	echo "== input devices"
	awk -F= '/^N: Name=/{n=$2} /^S: Sysfs=/{print "  " n "  " $2}' /proc/bus/input/devices |
		grep -iE 'asus|ally|xbox|keyboard|controller|0B05' || true
	echo
	echo "== press the buttons you want to check now, a couple of seconds apart"
	echo "   capturing for 10 seconds..."
	result=$(mktemp)
	capture 10 "$result"
	echo
	echo "== verdict"
	verdict "$result"
	rm -f "$result"
}

capture() {
	python3 -I - "$1" "$2" <<'PY'
import glob, os, select, struct, sys, time
NAMES = {183: "KEY_F13", 184: "KEY_F14", 185: "KEY_F15", 186: "KEY_F16 (QAM on Ally)",
         187: "KEY_F17", 188: "KEY_F18", 189: "KEY_F19", 190: "KEY_F20", 191: "KEY_F21",
         148: "KEY_PROG1", 149: "KEY_PROG2", 202: "KEY_PROG3", 203: "KEY_PROG4",
         316: "BTN_MODE", 304: "BTN_A", 305: "BTN_B", 314: "BTN_SELECT", 315: "BTN_START",
         125: "KEY_LEFTMETA", 29: "KEY_LEFTCTRL", 56: "KEY_LEFTALT", 111: "KEY_DELETE",
         32: "KEY_D", 23: "KEY_TAB"}
fds = {}
for path in sorted(glob.glob("/dev/input/event*")):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    except OSError:
        continue
    name = open("/sys/class/input/%s/device/name" % os.path.basename(path)).read().strip()
    fds[fd] = ("ev", path, name)
for path in sorted(glob.glob("/dev/hidraw*")):
    base = os.path.basename(path)
    try:
        uevent = open("/sys/class/hidraw/%s/device/uevent" % base).read()
    except OSError:
        continue
    if "0B05" not in uevent.upper():
        continue
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    except OSError:
        continue
    hid = [l.split("=", 1)[1] for l in uevent.splitlines() if l.startswith("HID_NAME=")]
    fds[fd] = ("raw", path, hid[0] if hid else "")
EV = struct.Struct("llHHi")
last = {}
end = time.time() + float(sys.argv[1])
seen = 0
codes = set()
keys = 0
while time.time() < end:
    r, _, _ = select.select(list(fds), [], [], 0.2)
    for fd in r:
        kind, path, name = fds[fd]
        try:
            data = os.read(fd, 4096)
        except OSError:
            continue
        if kind == "ev":
            for i in range(0, len(data) - EV.size + 1, EV.size):
                _, _, t, code, val = EV.unpack_from(data, i)
                if t == 1:  # EV_KEY
                    seen += 1
                    keys += 1
                    print("  %-18s %-28s %s %s" % (path, name[:28], NAMES.get(code, "key %d" % code),
                                                 "down" if val == 1 else "up" if val == 0 else "repeat"))
        else:
            hexs = data.hex(" ")
            if data[:1] == b"\x5a" and len(data) > 1 and data[1]:
                codes.add("%02x" % data[1])
            if data[:1] == b"\x5a" and last.get(fd) != hexs:
                seen += 1
                print("  %-18s %-28s raw %s" % (path, name[:28], hexs[:47]))
            last[fd] = hexs
if not seen:
    print("  nothing (no key events and no ASUS 0x5a reports)")
with open(sys.argv[2], "w") as f:
    f.write("codes=%s\nkeys=%d\n" % (" ".join(sorted(codes)), keys))
PY
}

verdict() {
	codes=$(sed -n 's/^codes=//p' "$1")
	keys=$(sed -n 's/^keys=//p' "$1")
	found=0
	for line in $(asus_hid_devices | tr ' ' '|'); do
		n=${line%%|*} pid=${line##*|}
		is_nkey_interface "$n" || continue
		found=1
		drv=$(driver_of "$n")
		echo "N-Key interface: $n (pid $pid), driver: $drv"
	done
	if [ "$found" = 0 ]; then
		echo "No ASUS N-Key interface found. Send the output above for a closer look."
		return
	fi
	if [ -z "$codes" ] && [ "${keys:-0}" = 0 ]; then
		echo "Nothing arrived while you pressed the button. Run it again and press during"
		echo "the 10 seconds; if it stays empty, send the output above."
	elif [ "${keys:-0}" -gt 0 ]; then
		echo "Key events arrived, so the kernel side works. If the menu still didn't open,"
		echo "Steam isn't mapping that key; send the output above."
	else
		echo "Vendor code(s) 0x$codes arrived, but no key event: the driver doesn't map"
		echo "them. On the X20, 0xa0 is the Quick Access button, which the X20 Fixes"
		echo "Decky plugin handles."
	fi
}

case ${1:-diagnose} in
diagnose) cmd_diagnose ;;
*) echo "usage: sudo $0"; exit 1 ;;
esac
