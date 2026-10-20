#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# ally-audio-fix.sh - internal speakers for the ASUS ROG Xbox Ally X20 on SteamOS.
#
# Four problems keep the speakers silent; this script fixes each one:
#
#  1. The BIOS sets ACPI "acp-audio-config-flag" = 0x10 (legacy, DMIC only), so the
#     SoundWire driver ignores the audio coprocessor. We load a copy of the ACPI table
#     with the flag cleared at boot (kernel ACPI table upgrade via an early initrd).
#  2. The kernel has no machine layout for retail boards, which put the two TAS2783
#     amps on SoundWire link 0. We load a rebuilt snd-soc-acpi-amd-match module with
#     that layout added (patches/0001-*.patch).
#  3. The amps need TI tuning files. We fetch the ones for this model from
#     linux-firmware, picking the speaker supplier variant from the BIOS SPEAKER_ID.
#  4. SteamOS's alsa-ucm-conf predates TAS2783 support, so PipeWire finds no speaker
#     device. We add upstream's sof-soundwire/tas2783.conf through a UCM overlay.
#
# Each step is skipped when SteamOS or the BIOS already handles it, so running
# "install" after an update only does what is still needed.
#
# Usage:
#   sudo ./ally-audio-fix.sh install     install or refresh what is needed (then reboot)
#   sudo ./ally-audio-fix.sh status      show what is active
#   sudo ./ally-audio-fix.sh check       same, as key=value lines (for scripts and the
#                                        Decky plugin); never changes anything
#   sudo ./ally-audio-fix.sh uninstall   remove everything (then reboot)
#        ./ally-audio-fix.sh build       build the module for the running kernel
#                                        (no sudo; needed after a kernel update)
#
# Only the booted SteamOS slot is changed. After a SteamOS update, run "install" again.
#
# ALLY_AUDIO_DATA sets where built modules and downloaded firmware are kept (default:
# next to this script). Keep it under /home so it survives SteamOS updates.

set -eu

REPO=$(cd "$(dirname "$0")" && pwd)
DATA=${ALLY_AUDIO_DATA:-$REPO}
KVER=$(uname -r)

# 1: ACPI override
KEY='acp-audio-config-flag'
EFI=/efi
CFG=$EFI/EFI/steamos/grub.cfg
CPIO_NAME=acpi_override.cpio

# 2-4: speaker support
LIB=/var/lib/ally-audio-fix
HOOK=$LIB/modprobe-hook.sh
MODCONF=/etc/modprobe.d/ally-audio-fix.conf
ENVCONF=/etc/environment.d/90-ally-audio-fix.conf
# Set by "uninstall"; /run is emptied at boot, so this means "removed, not rebooted yet".
REMOVED_MARK=/run/ally-audio-fix.removed
MODNAME=snd-soc-acpi-amd-match.ko
SVID=1043
SSID=1954

# Amp tuning files, pinned to a linux-firmware commit.
FW_COMMIT=a2dcb924f0897368b0b4f305cbf9808cdda90ce0
FW_URL=https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/ti/audio/tas2783
FW_NAMES="$SSID-0-0x8.bin $SSID-0-0xB.bin"
SPEAKER_ID_VAR=/sys/firmware/efi/efivars/SPEAKER_ID-aa61eaaf-6e83-7523-b0d0-7df74bb24a81

# SoundWire addresses of the two amps on link 0 (unique IDs 8 and 0xB). If the stock
# layout module already contains both, the kernel has the fix and we don't replace it.
TAS_L0_ADRS="0x0000380102000001 0x00003B0102000001"
# SoundWire address of the RT721 headset codec on link 1. A kernel whose layout table
# lacks it (SteamOS Stable's 6.18) predates the X20's audio support altogether, and one
# rebuilt module can't make up for that: the speakers need SteamOS Beta's newer kernel.
RT721_ADR=0x000130025D072101
# Product name fragment the kernel's ACP 7.0 flag-override DMI table would carry.
DMI_FRAGMENT=RC74XA

# Upstream kernel sources the module is built from.
KSRC_URL=https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain
KSRC_FILES="sound/soc/amd/mach-config.h
sound/soc/amd/acp/amd-acp63-acpi-match.c
sound/soc/amd/acp/amd-acp70-acpi-match.c
sound/soc/amd/acp/soc-acpi-amd-sdca-quirks.c
sound/soc/amd/acp/soc-acpi-amd-sdca-quirks.h"

ACP=$(lspci -Dnd 1022:15e2 2>/dev/null | awk 'NR==1{print $1}')
BOOT_ID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)
BIOS=$(cat /sys/class/dmi/id/bios_version 2>/dev/null || echo unknown)

die() { echo "error: $*" >&2; exit 1; }
note() { echo "==> $*"; }
need_root() { [ "$(id -u)" = 0 ] || die "run with sudo"; }

fw_sha256() {
	case $1 in
	1954-0-0-0x8.bin) echo e37c3efa1e92e72614175682c01cdcd4ceb7079878e8bafd3177c5a45dede434 ;;
	1954-0-0-0xB.bin) echo 655eb8754afc7284850988f330b6466ad782b7ae905ab7246621375a4784a8be ;;
	1954-1-0-0x8.bin) echo 677e3d033dcc8effc5247b771a5ecd08484c3740d0086b4cd333b07af06eb563 ;;
	1954-1-0-0xB.bin) echo 0d50eae7ae4f515304f4e8ce14832654ebf3447711c283bdbf7c175c9298de1d ;;
	*) return 1 ;;
	esac
}

# Returns 0 on the right hardware; prints the reason otherwise.
device_ok() {
	[ -n "$ACP" ] || { echo "no AMD ACP audio device (1022:15e2) found"; return 1; }
	svid=$(sed 's/^0x//' "/sys/bus/pci/devices/$ACP/subsystem_vendor")
	ssid=$(sed 's/^0x//' "/sys/bus/pci/devices/$ACP/subsystem_device")
	[ "$svid:$ssid" = "$SVID:$SSID" ] || {
		echo "audio subsystem ID is $svid:$ssid, expected $SVID:$SSID (ROG Xbox Ally X20)"
		return 1
	}
}

check_device() {
	why=$(device_ok) || die "$why; not touching it"
}

# Module built for the running kernel: a prebuilt one from the repo, or one from "build".
module_source() {
	for d in "$REPO/prebuilt/$KVER" "$DATA/build-out/$KVER" "$REPO/build-out/$KVER"; do
		[ -f "$d/$MODNAME" ] && { echo "$d/$MODNAME"; return 0; }
	done
	return 1
}

# Decompress a (possibly compressed) module and look for byte patterns or strings in it.
# usage: module_contains <module name> adr <hex>... | str <text>
module_contains() {
	path=$(modinfo -n "$1" 2>/dev/null) || return 1
	[ -f "$path" ] || return 1
	shift
	python3 -I - "$path" "$@" <<'PY'
import gzip, lzma, struct, subprocess, sys
path, kind, *needles = sys.argv[1:]
if path.endswith(".zst"):
    data = subprocess.run(["zstd", "-dcq", path], capture_output=True, check=True).stdout
elif path.endswith(".xz"):
    data = lzma.decompress(open(path, "rb").read())
elif path.endswith(".gz"):
    data = gzip.decompress(open(path, "rb").read())
else:
    data = open(path, "rb").read()
if kind == "adr":
    pats = [struct.pack("<Q", int(n, 16)) for n in needles]
else:
    pats = [n.encode() for n in needles]
sys.exit(0 if all(p in data for p in pats) else 1)
PY
}

# The kernel's own layout table already knows the link-0 amps (fixed upstream).
stock_has_layout() {
	# shellcheck disable=SC2086
	module_contains snd_soc_acpi_amd_match adr $TAS_L0_ADRS
}

# The kernel has the X20's audio support (everything but the link-0 layout).
kernel_supported() {
	module_contains snd_soc_acpi_amd_match adr "$RT721_ADR"
}

TOO_OLD="The speakers need SteamOS Beta (kernel 7.2 or newer); this kernel ($KVER) is too old. Switch the update channel to Beta in Settings > System, update, then apply the fix."

# The kernel already ignores the BIOS flag on this model (DMI quirk upstream).
kernel_has_flag_quirk() {
	module_contains snd_acp_config str "$DMI_FRAGMENT"
}

system_firmware() {
	for f in $FW_NAMES; do
		found=
		for p in /usr/lib/firmware/$f /usr/lib/firmware/$f.zst /usr/lib/firmware/$f.xz; do
			[ -f "$p" ] && found=1
		done
		[ -n "$found" ] || return 1
	done
}

our_firmware() {
	for f in $FW_NAMES; do [ -f "$LIB/firmware/$f" ] || return 1; done
}

speaker_card() {
	for n in $(aplay -l 2>/dev/null | sed -n 's/^card \([0-9]*\):.*/\1/p' | sort -u); do
		amixer -c "$n" info 2>/dev/null | grep -q 'spk:tas2783' && { echo "$n"; return 0; }
	done
	return 1
}

module_loaded() {
	m=$LIB/modules/$KVER/$MODNAME
	[ -f "$m" ] &&
		[ "$(cat /sys/module/snd_soc_acpi_amd_match/srcversion 2>/dev/null)" = "$(modinfo -F srcversion "$m")" ]
}

# --- 1: ACPI override ----------------------------------------------------------------

# Print "<table path> <offset of value byte> <value>" for the table holding the flag.
find_flag() {
	for t in /sys/firmware/acpi/tables/DSDT /sys/firmware/acpi/tables/SSDT*; do
		off=$(grep -abo "$KEY" "$t" 2>/dev/null | head -1 | cut -d: -f1) || true
		[ -n "$off" ] || continue
		# name + NUL, then 0x0A (BytePrefix), then the value byte
		voff=$((off + ${#KEY} + 2))
		prefix=$(od -An -tx1 -j $((voff - 1)) -N1 "$t" | tr -d ' ')
		val=$(od -An -tx1 -j "$voff" -N1 "$t" | tr -d ' ')
		[ "$prefix" = 0a ] || die "unexpected AML encoding in $t (prefix $prefix)"
		echo "$t $voff $val"
		return 0
	done
	return 1
}

efi_partuuid() {
	src=$(findmnt -no SOURCE "$EFI" | tail -1)
	[ -n "$src" ] || die "$EFI is not mounted"
	lsblk -no PARTUUID "$src"
}

boot_entries_patched() {
	grep -c "$CPIO_NAME" "$CFG" 2>/dev/null || true
}

build_cpio() {
	table=$1 voff=$2
	work=$(mktemp -d)
	mkdir -p "$work/kernel/firmware/acpi"
	python3 -I - "$table" "$voff" "$work/kernel/firmware/acpi/$(basename "$table" | tr '[:upper:]' '[:lower:]').aml" <<'PY'
import struct, sys
src, voff, dst = sys.argv[1], int(sys.argv[2]), sys.argv[3]
d = bytearray(open(src, 'rb').read())
assert d[voff - 1] == 0x0A and d[voff] == 0x10, "flag is not 0x10"
d[voff] = 0x00
struct.pack_into('<I', d, 24, struct.unpack_from('<I', d, 24)[0] + 1)  # bump OEM revision
d[9] = 0
d[9] = (-sum(d)) & 0xFF                                                  # fix checksum
open(dst, 'wb').write(d)
PY
	(cd "$work" && find kernel | bsdcpio -o -H newc --quiet) > "$work/$CPIO_NAME"
	cp "$work/$CPIO_NAME" "$LIB/$CPIO_NAME"
	rm -rf "$work"
	# The override is a full copy of this BIOS's table. Remember which BIOS it came
	# from: after a BIOS update it must be rebuilt, or the old table would replace
	# the new one at every boot.
	echo "$BIOS" > "$LIB/acpi-bios"
}

# The override was built from a different BIOS than the one running now.
acpi_stale() {
	[ -f "$LIB/acpi-bios" ] && [ "$(cat "$LIB/acpi-bios")" != "$BIOS" ]
}

install_acpi() {
	[ -f "$CFG" ] || die "$CFG not found (is this SteamOS?)"
	info=$(find_flag) || die "'$KEY' not found in ACPI tables; this fix does not apply"
	# shellcheck disable=SC2086
	set -- $info
	case $3 in
	10)
		note "ACPI: found $KEY=0x10 in $1, building override"
		build_cpio "$1" "$2"
		;;
	00)
		if [ ! -f "$LIB/$CPIO_NAME" ] && [ ! -f "$EFI/$CPIO_NAME" ]; then
			# Nothing of ours is loaded, so the BIOS itself reports 0 now.
			note "ACPI: the BIOS no longer sets the flag; no override needed"
			remove_acpi
			return 0
		fi
		# The override is active (this boot used it).
		acpi_stale && die "the BIOS changed from $(cat "$LIB/acpi-bios") to $BIOS since the ACPI override was built.
Run '$0 uninstall', reboot, then run install again so it is rebuilt from the new BIOS."
		[ -f "$LIB/$CPIO_NAME" ] || cp "$EFI/$CPIO_NAME" "$LIB/$CPIO_NAME"
		[ -f "$LIB/acpi-bios" ] || echo "$BIOS" > "$LIB/acpi-bios"
		note "ACPI: override already active"
		;;
	*) die "$KEY=0x$3, expected 0x10; not touching it" ;;
	esac

	cp "$LIB/$CPIO_NAME" "$EFI/$CPIO_NAME"
	if grep -q "$CPIO_NAME" "$CFG"; then
		note "ACPI: boot entry already patched"
	else
		uuid=$(efi_partuuid)
		cp "$CFG" "$CFG.pre-ally-audio-fix"
		sed -i "s|^\(\s*\)initrd\t|\1search --no-floppy --part-uuid --set=acpidev $uuid\n\1initrd\t(\$acpidev)/$CPIO_NAME |" "$CFG"
		if ! grub-script-check "$CFG"; then
			cp "$CFG.pre-ally-audio-fix" "$CFG"
			die "edited grub.cfg failed syntax check; restored original"
		fi
		grep -q "$CPIO_NAME" "$CFG" || die "no initrd lines found in $CFG"
		note "ACPI: patched boot entries:"
		grep -n "$CPIO_NAME" "$CFG"
	fi
}

# Undo the boot entry change, restoring the backup if the edit doesn't come out clean.
remove_acpi() {
	if [ -f "$CFG" ] && grep -q "$CPIO_NAME" "$CFG"; then
		cp "$CFG" "$CFG.ally-audio-fix.bak"
		sed -i -e "/--set=acpidev /d" -e "s|(\$acpidev)/$CPIO_NAME ||" "$CFG"
		if ! grub-script-check "$CFG" || grep -q "$CPIO_NAME" "$CFG"; then
			cp "$CFG.ally-audio-fix.bak" "$CFG"
			die "could not cleanly remove the ACPI override from $CFG; left it unchanged"
		fi
		rm -f "$CFG.ally-audio-fix.bak" "$CFG.pre-ally-audio-fix"
		note "ACPI: boot entries restored"
	fi
	rm -f "$EFI/$CPIO_NAME" "$LIB/$CPIO_NAME" "$LIB/acpi-bios"
}

# --- 2: layout module ----------------------------------------------------------------

install_module() {
	src=$(module_source) || die "no $MODNAME for kernel $KVER.
Build one first (as your normal user, no sudo): $0 build"
	if [ -f "$(dirname "$src")/SHA256SUMS" ]; then
		(cd "$(dirname "$src")" && sha256sum -c --quiet SHA256SUMS) || die "checksum mismatch for $src"
	fi
	vm=$(modinfo -F vermagic "$src" | awk '{print $1}')
	[ "$vm" = "$KVER" ] || die "$src is for kernel $vm, running $KVER"
	rm -rf "$LIB/modules"
	mkdir -p "$LIB/modules/$KVER"
	cp "$src" "$LIB/modules/$KVER/$MODNAME"
	note "module: installed for $KVER"
}

# --- 3: amp tuning files -------------------------------------------------------------

speaker_id() {
	[ -r "$SPEAKER_ID_VAR" ] || return 1
	# 4 bytes of EFI attributes, then the value
	od -An -tu4 -j4 -N4 "$SPEAKER_ID_VAR" | tr -d ' '
}

install_firmware() {
	if system_firmware; then
		note "firmware: SteamOS ships the amp tuning files; using those"
		rm -rf "$LIB/firmware"
		return 0
	fi
	id=$(speaker_id) || die "BIOS SPEAKER_ID variable not found; can't tell which speakers this unit has"
	case $id in
	0) vendor=JGX ;;
	1) vendor=LS ;;
	*) die "unexpected SPEAKER_ID $id" ;;
	esac
	note "firmware: SPEAKER_ID=$id ($vendor speakers)"
	mkdir -p "$LIB/firmware"
	cache=$DATA/cache/firmware
	mkdir -p "$cache" 2>/dev/null || cache=
	tmp=$(mktemp)
	for uid in 8 B; do
		# linux-firmware names: <ssid>-<speaker id>-<link>-0x<uid>
		# the driver requests:  <ssid>-<link>-0x<uid>
		src="$SSID-$id-0-0x$uid.bin"
		dst="$SSID-0-0x$uid.bin"
		sum=$(fw_sha256 "$src")
		# Reuse a verified copy if we have one, so re-applying works offline.
		if [ -n "$cache" ] && [ -f "$cache/$src" ] && echo "$sum  $cache/$src" | sha256sum -c --quiet 2>/dev/null; then
			cp "$cache/$src" "$tmp"
		elif [ -f "$LIB/firmware/$dst" ] && echo "$sum  $LIB/firmware/$dst" | sha256sum -c --quiet 2>/dev/null; then
			cp "$LIB/firmware/$dst" "$tmp"
		else
			curl -fsSL -o "$tmp" "$FW_URL/$src?id=$FW_COMMIT" || die "download of $src failed (no network?)"
			echo "$sum  $tmp" | sha256sum -c --quiet || die "checksum mismatch for $src"
		fi
		install -m 0644 "$tmp" "$LIB/firmware/$dst"
		[ -z "$cache" ] || install -m 0644 "$tmp" "$cache/$src" 2>/dev/null || true
		echo "    $src -> $LIB/firmware/$dst"
	done
	rm -f "$tmp"
}

# --- 4: UCM speaker profile ----------------------------------------------------------

install_ucm() {
	sys=/usr/share/alsa/ucm2
	if [ -f "$sys/sof-soundwire/tas2783.conf" ]; then
		note "UCM: SteamOS already ships tas2783.conf; no overlay needed"
		rm -f "$ENVCONF"
		rm -rf "$LIB/ucm2"
		return
	fi
	# A tree of symlinks to the system files, so SteamOS updates to them still apply,
	# plus the one missing profile.
	rm -rf "$LIB/ucm2"
	mkdir -p "$LIB/ucm2/sof-soundwire"
	for f in "$sys"/*; do
		[ "$(basename "$f")" = sof-soundwire ] || ln -s "$f" "$LIB/ucm2/"
	done
	for f in "$sys"/sof-soundwire/*; do
		ln -s "$f" "$LIB/ucm2/sof-soundwire/"
	done
	install -m 0644 "$REPO/ucm/tas2783.conf" "$LIB/ucm2/sof-soundwire/tas2783.conf"
	mkdir -p "$(dirname "$ENVCONF")"
	echo "ALSA_CONFIG_UCM2=$LIB/ucm2" > "$ENVCONF"
	note "UCM: overlay at $LIB/ucm2"
}

# --- hooks that load 2 and 3 at boot -------------------------------------------------

install_hooks() {
	cat > "$HOOK" <<EOF
#!/bin/sh
# Installed by ally-audio-fix.sh. Called by modprobe (see $MODCONF).
# Messages go to the kernel log: journalctl -k | grep ally-audio-fix
LIB=$LIB
log() { echo "ally-audio-fix: \$*" > /dev/kmsg 2>/dev/null || true; }
case \$1 in
match)
	# Use the module with the Ally X20 layout if one was built for this kernel;
	# otherwise fall back to the stock module (speakers stay off, nothing breaks).
	m=\$LIB/modules/\$(uname -r)/$MODNAME
	if [ -f "\$m" ]; then
		ok=1
		for d in \$(/usr/bin/modinfo -F depends "\$m" | tr , ' '); do
			/usr/bin/modprobe "\$d" || ok=0
		done
		if [ \$ok = 1 ] && /usr/bin/insmod "\$m"; then
			log "loaded layout module with link-0 amps"
			exit 0
		fi
		log "layout module failed to load; falling back to the stock one"
	fi
	exec /usr/bin/modprobe --ignore-install snd_soc_acpi_amd_match
	;;
tas2783)
	# Let the amp driver find its tuning files.
	if [ -n "\$(ls -A "\$LIB/firmware" 2>/dev/null)" ]; then
		p=/sys/module/firmware_class/parameters/path
		cur=\$(cat "\$p" 2>/dev/null || true)
		if [ -z "\$cur" ] && [ -w "\$p" ]; then
			printf %s "\$LIB/firmware" > "\$p"
		elif [ "\$cur" != "\$LIB/firmware" ]; then
			log "firmware_class.path is already '\$cur'; amp tuning files will not be found"
		fi
	fi
	exec /usr/bin/modprobe --ignore-install snd_soc_tas2783_sdw
	;;
esac
EOF
	chmod 0755 "$HOOK"
	{
		echo '# Installed by ally-audio-fix.sh; remove with "ally-audio-fix.sh uninstall".'
		[ ! -d "$LIB/modules" ] || echo "install snd_soc_acpi_amd_match /bin/sh $HOOK match"
		echo "install snd_soc_tas2783_sdw /bin/sh $HOOK tas2783"
	} > "$MODCONF"
	note "hooks: $MODCONF"

	if lsinitcpio "/boot/initramfs-$(pacman -Qqo "/usr/lib/modules/$KVER/vmlinuz").img" 2>/dev/null |
		grep -q 'snd-soc-acpi-amd-match'; then
		echo "warning: the initramfs contains the audio modules, so the hooks may not run" >&2
	fi
}

# --- state, for "status", "check" and the Decky plugin -------------------------------

# Sets acpi=, module=, firmware=, ucm=, hooks=, speakers=, state= and message=.
# Reads only; safe to call any time. Without root, ACPI details are "unknown".
compute_state() {
	supported=1
	why=$(device_ok) || supported=0
	installed_now=0
	[ "$(cat "$LIB/installed-boot-id" 2>/dev/null)" = "$BOOT_ID" ] && installed_now=1

	flag=unknown
	if [ "$(id -u)" = 0 ]; then
		info=$(find_flag 2>/dev/null) || info="- - none"
		flag=${info##* }
	fi
	patched=$(boot_entries_patched)
	if [ "$flag" = unknown ]; then
		acpi=unknown
	elif acpi_stale && [ "$flag" = 00 ]; then
		acpi=stale
	elif [ "$flag" = 00 ]; then
		if [ -f "$EFI/$CPIO_NAME" ]; then acpi=override_active; else acpi=not_needed; fi
	elif [ "$flag" = 10 ] && kernel_has_flag_quirk; then
		acpi=not_needed
	elif [ "$flag" = 10 ] && [ "${patched:-0}" -gt 0 ] && [ -f "$EFI/$CPIO_NAME" ]; then
		# Installed but not in effect: fine until the next boot, a problem after it
		# (the kernel only takes an override whose OEM revision beats the BIOS's own,
		# so a BIOS update that bumps it makes the kernel ignore ours).
		if [ "$installed_now" = 1 ]; then acpi=override_pending; else acpi=override_ignored; fi
	elif [ "$flag" = 10 ]; then
		acpi=needed
	else
		acpi=unknown
	fi

	if module_loaded; then module=loaded
	elif [ -f "$LIB/modules/$KVER/$MODNAME" ]; then module=installed
	elif stock_has_layout; then module=not_needed
	elif ! kernel_supported; then module=kernel_too_old
	elif module_source > /dev/null; then module=available
	else module=missing
	fi

	if our_firmware; then firmware=installed
	elif system_firmware; then firmware=system
	else firmware=missing
	fi

	if [ -f /usr/share/alsa/ucm2/sof-soundwire/tas2783.conf ]; then ucm=system
	elif [ -f "$ENVCONF" ] && [ -f "$LIB/ucm2/sof-soundwire/tas2783.conf" ]; then ucm=overlay
	else ucm=missing
	fi

	hooks=0
	[ -f "$MODCONF" ] && [ -x "$HOOK" ] && hooks=1

	speakers=0
	speaker_card > /dev/null && speakers=1

	ours=0
	{ [ "$module" = loaded ] || [ "$acpi" = override_active ] ||
	  [ "$firmware" = installed ] || [ "$ucm" = overlay ]; } && ours=1

	if [ "$supported" = 0 ]; then
		state=unsupported message="$why"
	elif [ -f "$REMOVED_MARK" ]; then
		state=needs_reboot message="The fix was removed. Reboot to finish."
	elif [ "$acpi" = stale ] || [ "$acpi" = override_ignored ]; then
		state=acpi_stale message="The BIOS was updated after the ACPI fix was made. Remove the fix, reboot, then apply it again."
	elif [ "$module" = kernel_too_old ] && [ "$speakers" = 0 ]; then
		state=kernel_too_old message="$TOO_OLD"
	elif [ "$speakers" = 1 ] && [ "$ucm" != missing ] && [ "$firmware" != missing ]; then
		if [ "$ours" = 1 ]; then
			state=ok message="Speakers are working with the fix."
		else
			state=fixed_upstream message="Speakers work without the fix. SteamOS has caught up; the fix can be removed."
		fi
	elif [ "$module" = missing ] && [ "$speakers" = 0 ]; then
		state=needs_build message="No layout module for kernel $KVER yet. Build one (needs internet, takes several minutes)."
	elif [ "$acpi" = needed ] || [ "$module" = available ] || [ "$firmware" = missing ] ||
		[ "$ucm" = missing ] || [ "$hooks" = 0 ]; then
		state=needs_install message="The fix is not (or no longer) applied to this SteamOS slot."
	elif [ "$installed_now" = 1 ]; then
		state=needs_reboot message="The fix is installed. Reboot to turn the speakers on."
	elif [ "$module" = installed ]; then
		state=broken message="The layout module is installed but did not load. See: journalctl -k | grep ally-audio-fix"
	else
		state=broken message="Everything is installed but the speakers did not come up. See: journalctl -k | grep -iE 'ally-audio-fix|tas2783|soundwire'"
	fi
}

# --- commands ------------------------------------------------------------------------

cmd_install() {
	need_root
	check_device
	echo "device: $(cat /sys/class/dmi/id/product_name), BIOS $BIOS, kernel $KVER"
	compute_state
	if [ "$state" = fixed_upstream ]; then
		note "speakers already work on this SteamOS build; nothing to install"
		[ ! -e "$LIB" ] || echo "You can remove the leftovers with: sudo $0 uninstall"
		return 0
	fi
	[ "$state" != kernel_too_old ] || die "$TOO_OLD"
	mkdir -p "$LIB"
	need_module=1
	if stock_has_layout; then
		need_module=0
		note "module: this kernel already knows the link-0 amps; keeping the stock module"
		rm -rf "$LIB/modules"
	fi
	# Check everything that can fail before changing the boot setup.
	if [ "$need_module" = 1 ]; then
		module_source > /dev/null || die "no $MODNAME for kernel $KVER.
Build one first (as your normal user, no sudo): $0 build"
	fi
	install_firmware
	[ "$need_module" = 0 ] || install_module
	install_ucm
	install_hooks
	if kernel_has_flag_quirk; then
		note "ACPI: this kernel already ignores the BIOS flag on this model; no override needed"
		remove_acpi
	else
		install_acpi
	fi
	echo "$BOOT_ID" > "$LIB/installed-boot-id"
	rm -f "$REMOVED_MARK"
	sync
	echo
	echo "Done. Reboot, then check with: sudo $0 status"
}

cmd_uninstall() {
	need_root
	remove_acpi
	rm -f "$MODCONF" "$ENVCONF"
	rm -rf "$LIB"
	: > "$REMOVED_MARK" 2>/dev/null || true
	sync
	echo "Removed from this slot. Reboot to apply."
}

cmd_check() {
	compute_state
	fw_path=$(cat /sys/module/firmware_class/parameters/path 2>/dev/null || true)
	cat <<EOF
state=$state
message=$message
device=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)
bios=$BIOS
kernel=$KVER
supported=$supported
acpi=$acpi
acpi_flag=$flag
boot_entries=${patched:-0}
module=$module
firmware=$firmware
ucm=$ucm
hooks=$hooks
speakers=$speakers
speaker_id=$(speaker_id 2>/dev/null || echo unknown)
fw_path=$fw_path
EOF
}

cmd_status() {
	compute_state
	echo "state:     $state - $message"
	echo "device:    $(cat /sys/class/dmi/id/product_name) (BIOS $BIOS)"
	echo "kernel:    $KVER"
	if [ -n "$ACP" ]; then
		drv=$(readlink "/sys/bus/pci/devices/$ACP/driver" 2>/dev/null || true)
		echo "ACP:       $ACP driver=$(basename "${drv:-none}")"
	fi
	if [ "$(id -u)" = 0 ]; then
		echo "ACPI flag: $KEY=0x$flag ($acpi)"
		echo "boot cfg:  ${patched:-0} patched entries"
		echo "speakers:  SPEAKER_ID=$(speaker_id || echo '?')"
	else
		echo "(run with sudo for ACPI and boot details)"
	fi
	echo "module:    $module"
	echo "firmware:  $firmware $(ls "$LIB/firmware" 2>/dev/null | tr '\n' ' ')"
	echo "UCM:       $ucm"
	if n=$(speaker_card); then
		echo "card:      $(amixer -c "$n" info 2>/dev/null | sed -n 's/.*Components\s*: //p')"
	fi
	aplay -l 2>/dev/null | grep '^card' | sed 's/^/           /'
}

cmd_build() {
	[ "$(id -u)" != 0 ] || die "run build as your normal user (it uses rootless podman, stored in your home)"
	kernel_supported || die "$TOO_OLD"
	command -v podman > /dev/null || die "podman not found"
	pkg=$(pacman -Qo "/usr/lib/modules/$KVER/vmlinuz" | awk '{print $(NF-1), $NF}')
	# shellcheck disable=SC2086
	set -- $pkg
	name=$1 ver=$2
	# 7.2.7-valve2-... -> v7.2.7; 7.2.0-... -> v7.2
	base=${KVER%%-*}
	case $base in *.0) base=${base%.0} ;; esac
	out="$DATA/build-out/$KVER"
	mkdir -p "$HOME/.cache"
	work=$(mktemp -d "$HOME/.cache/ally-audio-build.XXXXXX")
	trap 'rm -rf "$work"' EXIT
	note "kernel package $name $ver, upstream v$base"

	hdr="$name-headers-$ver-x86_64.pkg.tar.zst"
	mirror=https://steamdeck-packages.steamos.cloud/archlinux-mirror
	for repo in $(sed -n 's/^\[\(.*\)\]$/\1/p' /etc/pacman.conf | grep -v options); do
		curl -fsSL -o "$work/$hdr" "$mirror/$repo/os/x86_64/$hdr" 2>/dev/null && break
	done
	[ -s "$work/$hdr" ] || die "could not download $hdr"
	note "downloaded $hdr"
	mkdir -p "$work/hdr"
	tar --zstd -xf "$work/$hdr" -C "$work/hdr"

	mkdir -p "$work/src/amd/acp"
	for f in $KSRC_FILES; do
		curl -fsSL -o "$work/src/${f#sound/soc/}" "$KSRC_URL/$f?h=v$base" || die "download of $f failed"
	done
	cp "$REPO/patches/0001-ASoC-amd-acp70-add-TAS2783-x2-on-link-0-with-RT721-on-link-1.patch" "$work/layout.patch"
	cat > "$work/src/amd/acp/Makefile" <<'EOF'
snd-soc-acpi-amd-match-y := amd-acp63-acpi-match.o amd-acp70-acpi-match.o soc-acpi-amd-sdca-quirks.o
obj-m += snd-soc-acpi-amd-match.o
EOF
	note "building in an Arch Linux container (first run downloads ~500 MB)"
	podman run --rm -v "$work:/w:Z" docker.io/library/archlinux:latest sh -c "
		pacman -Sy --noconfirm --needed base-devel bc kmod libelf pahole zstd > /dev/null &&
		{ (cd /w/src && patch -s -p3 < /w/layout.patch) ||
		  { echo 'patch does not apply to v$base; the kernel source changed' >&2; exit 1; }; } &&
		make -s -C /w/hdr/usr/lib/modules/$KVER/build M=/w/src/amd/acp modules" ||
		die "build failed"
	m="$work/src/amd/acp/$MODNAME"
	[ "$(modinfo -F vermagic "$m" | awk '{print $1}')" = "$KVER" ] || die "built module has the wrong vermagic"
	[ "$(modinfo -F depends "$m")" = "$(modinfo -F depends snd_soc_acpi_amd_match)" ] ||
		echo "warning: module dependencies differ from the stock module" >&2
	# The rebuilt file replaces the whole stock table. It is built from upstream stable
	# sources, which can lack layouts Valve backported. Those would only matter on other
	# hardware (this module only loads on the X20), but say so if it happens.
	missing=$(python3 -I - "$(modinfo -n snd_soc_acpi_amd_match)" "$m" <<'PY'
import subprocess, sys, tempfile
def syms(path):
    if path.endswith(".zst"):
        data = subprocess.run(["zstd", "-dcq", path], capture_output=True, check=True).stdout
        with tempfile.NamedTemporaryFile(suffix=".ko") as f:
            f.write(data)
            f.flush()
            out = subprocess.run(["nm", f.name], capture_output=True, text=True).stdout
    else:
        out = subprocess.run(["nm", path], capture_output=True, text=True).stdout
    return {l.split()[-1] for l in out.splitlines() if l.strip()}
stock, built = syms(sys.argv[1]), syms(sys.argv[2])
# Layout tables are static data named acp63_* / acp70_*.
print(" ".join(sorted(s for s in stock - built if s.startswith(("acp63_", "acp70_")))))
PY
) || missing=
	[ -z "$missing" ] ||
		echo "warning: SteamOS's stock module has layouts this build lacks: $missing" >&2
	strings "$m" | grep -q acp70_tas2783x2_l0u8b_rt721_l1u0 || die "built module lacks the new layout"
	mkdir -p "$out"
	cp "$m" "$out/"
	(cd "$out" && sha256sum "$MODNAME" > SHA256SUMS)
	note "built $out/$MODNAME"
	echo "Now run: sudo $0 install"
}

case ${1:-} in
install) cmd_install ;;
uninstall) cmd_uninstall ;;
status) cmd_status ;;
check) cmd_check ;;
build) cmd_build ;;
*)
	echo "usage: sudo $0 install|status|check|uninstall"
	echo "       $0 build    (no sudo; after a kernel update)"
	exit 1
	;;
esac
