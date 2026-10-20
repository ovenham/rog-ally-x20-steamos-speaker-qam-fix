#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Runs ally-audio-fix.sh against a simulated ROG Xbox Ally X20, without touching the
# real system: everything it reads and writes (/sys, /efi, /etc/modprobe.d, /var/lib,
# ...) is replaced by throwaway tmpfs mounts in a private mount namespace, and the
# hardware tools (lspci, modinfo, amixer, ...) are replaced by small fakes.
#
# Needs root (for unshare -m) on any Linux box. From the repo root:
#   sudo speaker-fix/tests/run.sh                    # the script on its own
#   sudo PLUGIN=plugin speaker-fix/tests/run.sh      # plus the Decky plugin backend
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
[ -z "${PLUGIN:-}" ] || PLUGIN=$(cd "$PLUGIN" && pwd)
export PLUGIN
[ "$(id -u)" = 0 ] || { echo "needs root (it uses a private mount namespace)" >&2; exit 1; }
# Mount points that don't exist on a non-SteamOS box.
mkdir -p /efi /etc/modprobe.d /etc/environment.d /usr/share/alsa /usr/lib/firmware
exec unshare -m --propagation private sh "$HERE/scenarios.sh" "$(dirname "$HERE")"
