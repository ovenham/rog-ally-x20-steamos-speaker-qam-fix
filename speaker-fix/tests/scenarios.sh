#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Called by run.sh inside a private mount namespace. Do not run directly.
set -eu
REPO=$1
FIX="$REPO/ally-audio-fix.sh"
T=$(mktemp -d)
KVER1=7.2.7-valve2-1-neptune-72-g31504582a073   # has a prebuilt module in the repo
KVER2=7.3.1-valve1-1-neptune-73-g0123456789ab   # a later SteamOS kernel
KVER3=7.3.2-valve1-1-neptune-73-g0123456789ab   # and the one after that
export ALLY_AUDIO_DATA=$T/data
PASS=0 FAIL=0

# --- throwaway system ------------------------------------------------------------------

for m in /sys/firmware /sys/class /sys/bus/pci /sys/module /efi /var/lib /run \
	/etc/modprobe.d /etc/environment.d /usr/share/alsa /usr/lib/firmware; do
	mount -t tmpfs fake "$m"
done
mkdir -p /sys/firmware/acpi/tables /sys/firmware/efi/efivars /sys/class/dmi/id \
	/sys/bus/pci/devices/0000:c4:00.5 /sys/module/firmware_class/parameters \
	/sys/module/snd_soc_acpi_amd_match /efi/EFI/steamos \
	/usr/share/alsa/ucm2/sof-soundwire /usr/share/alsa/ucm2/common \
	"$T/bin" "$T/knobs" "$T/stock/$KVER1" "$T/stock/$KVER2" "$T/stock/$KVER3"
: > /sys/module/firmware_class/parameters/path
echo "ROG XBOX Ally X RC74XA" > /sys/class/dmi/id/product_name
echo RC74XA.301 > /sys/class/dmi/id/bios_version
echo 0x1043 > /sys/bus/pci/devices/0000:c4:00.5/subsystem_vendor
echo 0x1954 > /sys/bus/pci/devices/0000:c4:00.5/subsystem_device
printf '\007\000\000\000\000\000\000\000' > /sys/firmware/efi/efivars/SPEAKER_ID-aa61eaaf-6e83-7523-b0d0-7df74bb24a81
echo 'Syntax 4' > /usr/share/alsa/ucm2/sof-soundwire/sof-soundwire.conf
echo "$KVER1" > "$T/knobs/kver"
echo 0 > "$T/knobs/oemrev_bump"
echo 0 > "$T/knobs/grubfail"
cat /proc/sys/kernel/random/boot_id > "$T/boot_id"
mount --bind "$T/boot_id" /proc/sys/kernel/random/boot_id

cat > /efi/EFI/steamos/grub.cfg <<'EOF'
menuentry 'SteamOS' {
	search --no-floppy --set=root --part-uuid 11111111-0000-0000-0000-000000000000
	linux	/boot/vmlinuz-linux-neptune-72 root=PARTUUID=x rw quiet
	initrd	/boot/amd-ucode.img /boot/initramfs-linux-neptune-72.img
}
menuentry 'SteamOS (fallback initramfs)' {
	search --no-floppy --set=root --part-uuid 11111111-0000-0000-0000-000000000000
	linux	/boot/vmlinuz-linux-neptune-72 root=PARTUUID=x rw
	initrd	/boot/initramfs-linux-neptune-72-fallback.img
}
EOF
cp /efi/EFI/steamos/grub.cfg "$T/grub.cfg.orig"

# ACPI table with the flag, as the BIOS (or our override) would present it.

# Stock modules: the repo's prebuilt one is the "fixed" layout table. A copy with the
# link-0 amp addresses and srcversion blanked stands in for the stock one.
PREBUILT="$REPO/prebuilt/$KVER1/snd-soc-acpi-amd-match.ko"
python3 -I - "$PREBUILT" "$T/stock-nolayout.ko" <<'PY'
import struct, sys
d = open(sys.argv[1], "rb").read()
for a in (0x0000380102000001, 0x00003B0102000001):
    d = d.replace(struct.pack("<Q", a), struct.pack("<Q", 0))
d = d.replace(b"srcversion=C9791CC88BEC1C2A6AFFD77", b"srcversion=STOCK0000000000000000")
open(sys.argv[2], "wb").write(d)
PY
cp "$T/stock-nolayout.ko" "$T/stock/$KVER1/snd_soc_acpi_amd_match.ko"
cp "$T/stock-nolayout.ko" "$T/stock/$KVER2/snd_soc_acpi_amd_match.ko"
for k in "$KVER1" "$KVER2" "$KVER3"; do echo "no quirk here" > "$T/stock/$k/snd_acp_config.ko"; done

# --- fake tools ------------------------------------------------------------------------

fake() { cat > "$T/bin/$1"; chmod +x "$T/bin/$1"; }
fake uname <<EOF
#!/bin/sh
[ "\${1:-}" = -r ] && exec cat "$T/knobs/kver"
exec /usr/bin/uname "\$@"
EOF
fake lspci <<'EOF'
#!/bin/sh
echo "0000:c4:00.5 0480: 1022:15e2 (rev 70)"
EOF
fake modinfo <<EOF
#!/usr/bin/env python3
import os, sys
args = sys.argv[1:]
kver = open("$T/knobs/kver").read().strip()
def path(t):
    return t if "/" in t else "$T/stock/%s/%s.ko" % (kver, t.replace("-", "_"))
if args[0] == "-n":
    p = path(args[1]); print(p) if os.path.exists(p) else sys.exit(1)
elif args[0] == "-F":
    d = open(path(args[2]), "rb").read(); key = args[1].encode() + b"="
    i = d.find(key)
    if i >= 0: print(d[i + len(key): d.index(b"\0", i)].decode())
EOF
fake aplay <<EOF
#!/bin/sh
echo "card 0: amdsoundwire [amd-soundwire], device 0: Jack [Jack]"
EOF
fake amixer <<EOF
#!/bin/sh
if [ "\$(cat "$T/knobs/speakers" 2>/dev/null)" = 1 ]; then
	echo "  Components      : 'HDA:... cfg-amp:2 spk:tas2783 hs:rt721'"
else
	echo "  Components      : 'HDA:... hs:rt721'"
fi
EOF
fake grub-script-check <<EOF
#!/bin/sh
[ "\$(cat "$T/knobs/grubfail")" = 0 ]
EOF
fake findmnt <<'EOF'
#!/bin/sh
echo /dev/nvme0n1p2
EOF
fake lsblk <<'EOF'
#!/bin/sh
echo 22222222-0000-0000-0000-000000000000
EOF
fake lsinitcpio <<'EOF'
#!/bin/sh
exit 0
EOF
fake pacman <<'EOF'
#!/bin/sh
echo linux-neptune
EOF
fake curl <<'EOF'
#!/bin/sh
echo "curl: (6) Could not resolve host (fake: no network in tests)" >&2
exit 6
EOF
fake bsdcpio <<'EOF'
#!/usr/bin/env python3
# Minimal "find ... | bsdcpio -o -H newc" for the test.
import os, sys
out = sys.stdout.buffer
def entry(name, data, mode):
    hdr = "070701%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X" % (
        0, mode, 0, 0, 1, 0, len(data), 0, 0, 0, 0, len(name) + 1, 0)
    out.write(hdr.encode() + name.encode() + b"\0")
    out.write(b"\0" * ((4 - (110 + len(name) + 1) % 4) % 4))
    out.write(data); out.write(b"\0" * ((4 - len(data) % 4) % 4))
for name in sys.stdin.read().split():
    if os.path.isdir(name): entry(name, b"", 0o40755)
    else: entry(name, open(name, "rb").read(), 0o100644)
entry("TRAILER!!!", b"", 0)
EOF
export PATH="$T/bin:$PATH"

# --- what a reboot does ----------------------------------------------------------------

# Simulation helpers, also used by the Decky backend test (sh "$T/sim.sh" reboot).
cat > "$T/sim.sh" <<SIM_EOF
T=$T
export PATH="$T/bin:\$PATH"
SIM_EOF
cat >> "$T/sim.sh" <<'SIM_EOF'
make_table() { # <flag hex> <oem revision>
	python3 -I - "$1" "$2" /sys/firmware/acpi/tables/SSDT3 <<'PY'
import struct, sys
flag, rev, dst = int(sys.argv[1], 16), int(sys.argv[2]), sys.argv[3]
body = b"\x10\x20\x5fSB_" + b"\x0dacp-audio-config-flag\x00\x0a" + bytes([flag]) + b"\xa3" * 16
hdr = bytearray(b"SSDT" + struct.pack("<I", 36 + len(body)) + b"\x02\x00" + b"ALASKA" + b"AcpAudio"
                + struct.pack("<I", rev) + b"INTL" + struct.pack("<I", 0x20250404))
d = hdr + body
d[9] = (-sum(d)) & 0xFF
open(dst, "wb").write(d)
PY
	printf 'DSDT\044\000\000\000' > /sys/firmware/acpi/tables/DSDT
}

reboot() {
	cat /proc/sys/kernel/random/uuid > "$T/boot_id"
	rm -f /run/ally-audio-fix.removed
	if [ -f "$T/knobs/next_kver" ]; then
		mv "$T/knobs/next_kver" "$T/knobs/kver"
		cp "$T/grub.cfg.orig" /efi/EFI/steamos/grub.cfg   # new slot, fresh boot config
		rm -f /efi/acpi_override.cpio
	fi
	kver=$(cat "$T/knobs/kver")
	bios_rev=$((1 + $(cat "$T/knobs/oemrev_bump")))
	flag=10
	if [ -f /efi/acpi_override.cpio ] && grep -q acpi_override.cpio /efi/EFI/steamos/grub.cfg &&
		[ "$bios_rev" -lt 2 ]; then
		flag=00 # the kernel takes our table (OEM revision 2) over the BIOS's
	fi
	make_table "$flag" "$bios_rev"
	ours=/var/lib/ally-audio-fix/modules/$kver/snd-soc-acpi-amd-match.ko
	layout=0
	if [ -f "$ours" ] && grep -q 'install snd_soc_acpi_amd_match' /etc/modprobe.d/ally-audio-fix.conf 2>/dev/null; then
		modinfo -F srcversion "$ours" > /sys/module/snd_soc_acpi_amd_match/srcversion
		layout=1
	else
		modinfo -F srcversion snd_soc_acpi_amd_match > /sys/module/snd_soc_acpi_amd_match/srcversion
		python3 -I -c 'import struct,sys; sys.exit(0 if struct.pack("<Q",0x0000380102000001) in open(sys.argv[1],"rb").read() else 1)' \
			"$(modinfo -n snd_soc_acpi_amd_match)" && layout=1
	fi
	quirk=0
	grep -q RC74XA "$(modinfo -n snd_acp_config)" && quirk=1
	if { [ "$flag" = 00 ] || [ "$quirk" = 1 ]; } && [ "$layout" = 1 ]; then
		echo 1 > "$T/knobs/speakers"
	else
		echo 0 > "$T/knobs/speakers"
	fi
}
[ "${1:-}" != reboot ] || reboot
SIM_EOF
. "$T/sim.sh"
make_table 10 1

# --- assertions ------------------------------------------------------------------------

ok() { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $*"; }
expect() { # <key> <value>
	got=$(sh "$FIX" check | sed -n "s/^$1=//p")
	[ "$got" = "$2" ] && ok "$1=$2" || bad "$1: expected '$2', got '$got'"
}
expect_fail() { # <grep pattern> <command...>
	pat=$1; shift
	if out=$("$@" 2>&1); then bad "expected failure: $*"; return; fi
	echo "$out" | grep -q "$pat" && ok "fails with: $pat" || { bad "wrong error for $*:"; echo "$out" | sed 's/^/       /'; }
}
expect_ok() { # <command...>
	if out=$("$@" 2>&1); then ok "succeeds: $*"; else bad "failed: $*"; echo "$out" | sed 's/^/       /'; fi
}
same_grub() {
	cmp -s "$T/grub.cfg.orig" /efi/EFI/steamos/grub.cfg && ok "grub.cfg $1" || { bad "grub.cfg $1"; diff "$T/grub.cfg.orig" /efi/EFI/steamos/grub.cfg || true; }
}

# --- scenarios -------------------------------------------------------------------------

echo "1. fresh unit, nothing installed"
expect state needs_install
expect acpi needed
expect module available

echo "2. install with no network and no firmware: fails before touching boot config"
expect_fail "download of 1954-0-0-0x8.bin failed" sh "$FIX" install
same_grub "untouched after failed install"

echo "3. install with the tuning files available"
for f in 1954-0-0x8.bin 1954-0-0xB.bin; do echo fw > "/usr/lib/firmware/$f.zst"; done
expect_ok sh "$FIX" install
expect state needs_reboot
[ "$(grep -c acpi_override.cpio /efi/EFI/steamos/grub.cfg)" = 2 ] && ok "both boot entries patched" || bad "boot entries not patched"
grep -q 'initrd	(\$acpidev)/acpi_override.cpio /boot/amd-ucode.img' /efi/EFI/steamos/grub.cfg &&
	ok "override is the first initrd" || bad "override is not the first initrd"
sh -n /var/lib/ally-audio-fix/modprobe-hook.sh && ok "generated hook parses" || bad "generated hook has a syntax error"
grep -q 'install snd_soc_acpi_amd_match' /etc/modprobe.d/ally-audio-fix.conf && ok "match hook registered" || bad "match hook missing"
[ -f /etc/environment.d/90-ally-audio-fix.conf ] && ok "UCM overlay env set" || bad "UCM overlay env missing"

echo "4. after reboot"
reboot
expect state ok
expect acpi override_active
expect module loaded
expect firmware system

echo "5. install again is harmless"
expect_ok sh "$FIX" install
[ "$(grep -c acpi_override.cpio /efi/EFI/steamos/grub.cfg)" = 2 ] && ok "boot entries not patched twice" || bad "boot entries patched twice"
reboot
expect state ok

echo "6. BIOS updated in Windows, same ACPI OEM revision (old table would be reloaded)"
echo RC74XA.302 > /sys/class/dmi/id/bios_version
reboot
expect state acpi_stale
expect_fail "the BIOS changed from RC74XA.301 to RC74XA.302" sh "$FIX" install

echo "7. uninstall restores the original boot config"
expect_ok sh "$FIX" uninstall
expect state needs_reboot
same_grub "identical to the original after uninstall"
[ ! -e /var/lib/ally-audio-fix ] && [ ! -e /etc/modprobe.d/ally-audio-fix.conf ] && [ ! -e /efi/acpi_override.cpio ] &&
	ok "all files removed" || bad "files left behind"
reboot
expect state needs_install

echo "8. reinstall on the new BIOS, then the BIOS bumps its ACPI revision (kernel ignores override)"
expect_ok sh "$FIX" install
reboot
expect state ok
echo RC74XA.303 > /sys/class/dmi/id/bios_version
echo 1 > "$T/knobs/oemrev_bump"
reboot
expect state acpi_stale
expect acpi override_ignored
expect_ok sh "$FIX" uninstall
echo 0 > "$T/knobs/oemrev_bump"
reboot

echo "9. grub.cfg edit that fails the syntax check is rolled back"
echo 1 > "$T/knobs/grubfail"
expect_fail "failed syntax check; restored original" sh "$FIX" install
same_grub "restored after failed check"
echo 0 > "$T/knobs/grubfail"
expect_ok sh "$FIX" install
reboot
expect state ok

echo "10. SteamOS update to a kernel with no module yet"
echo "$KVER2" > "$T/knobs/next_kver"
reboot
expect state needs_build
expect acpi needed
expect_fail "no snd-soc-acpi-amd-match.ko for kernel $KVER2" sh "$FIX" install
same_grub "untouched when the module is missing"

echo "11. module built for the new kernel (simulated build-out), re-apply"
mkdir -p "$ALLY_AUDIO_DATA/build-out/$KVER2"
python3 -I - "$PREBUILT" "$ALLY_AUDIO_DATA/build-out/$KVER2/snd-soc-acpi-amd-match.ko" "$KVER1" "$KVER2" <<'PY'
import sys
d = open(sys.argv[1], "rb").read()
a, b = sys.argv[3].encode(), sys.argv[4].encode()
assert len(a) == len(b)
open(sys.argv[2], "wb").write(d.replace(a, b))
PY
expect state needs_install
expect_ok sh "$FIX" install
reboot
expect state ok

echo "12. SteamOS update whose kernel has the layout, but not the UCM profile"
echo "$KVER3" > "$T/knobs/next_kver"
cp "$PREBUILT" "$T/stock/$KVER3/snd_soc_acpi_amd_match.ko"
reboot
expect module not_needed
expect_ok sh "$FIX" install
grep -q 'install snd_soc_acpi_amd_match' /etc/modprobe.d/ally-audio-fix.conf &&
	bad "match hook registered although the kernel has the layout" || ok "stock layout module kept"
reboot
expect state ok

echo "13. SteamOS fully catches up: kernel quirk, UCM profile, firmware"
echo "quirk for RC74XA" > "$T/stock/$KVER3/snd_acp_config.ko"
echo 'Syntax 4' > /usr/share/alsa/ucm2/sof-soundwire/tas2783.conf
expect_ok sh "$FIX" uninstall
reboot
expect state fixed_upstream
expect acpi not_needed
expect_ok sh "$FIX" install
[ ! -e /etc/modprobe.d/ally-audio-fix.conf ] && ok "install does nothing once fixed upstream" || bad "install changed things"

echo "14. not an X20"
echo 0x1955 > /sys/bus/pci/devices/0000:c4:00.5/subsystem_device
expect state unsupported
expect_fail "expected 1043:1954" sh "$FIX" install

if [ -n "${PLUGIN:-}" ]; then
	echo "15. Decky plugin backend (main.py) on a fresh, unfixed unit"
	echo 0x1954 > /sys/bus/pci/devices/0000:c4:00.5/subsystem_device
	echo "$KVER1" > "$T/knobs/next_kver"
	rm -f /usr/share/alsa/ucm2/sof-soundwire/tas2783.conf
	reboot
	expect state needs_install
	if python3 -I "$PLUGIN/tests/backend_test.py" "$PLUGIN" "$REPO" "sh $T/sim.sh reboot"; then
		ok "backend test"
	else
		bad "backend test"
	fi
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
