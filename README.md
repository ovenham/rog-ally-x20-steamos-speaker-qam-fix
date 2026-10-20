# X20 Fixes: speakers and Quick Access button for the ROG Xbox Ally X20 on SteamOS

Running SteamOS on the ASUS ROG Xbox Ally X20? This fixes two things that don't
work out of the box:

- **The internal speakers** (shows auto_null)
- **The Quick Access button** on the right side (workaround with Xbox + A)

## Install

You'll need about 10 minutes and an internet connection.

### Step 1: In Desktop Mode

1. Hold the **power button** and choose **Switch to Desktop**.
2. **Set a password**, if you've never set one. Open **Konsole** (in the app
   menu, under System), type `passwd`, press Enter, and type a new password twice.
   Nothing shows on screen while you type; that's normal. Press **Steam + X**
   to bring up the on-screen keyboard.
3. **Install Decky Loader**, if you don't have it. Go to
   [decky.xyz](https://decky.xyz) in the browser, download the installer, run
   it, choose the release version, and enter your password when asked.
4. **Download [`x20-fixes.zip`](https://github.com/ovenham/rog-ally-x20-steamos-speaker-qam-fix/releases/latest/download/x20-fixes.zip)**.
   It saves to your Downloads folder. Don't unzip it.
5. Double-click **Return to Gaming Mode** on the desktop.

### Step 2: In Game Mode

1. Press **Xbox + A** to open the Quick Access menu, then select the **plug
   icon** (Decky).
2. Select the **gear icon**, and turn on **Developer mode**.
3. Go to the new **Developer** section and choose **Install Plugin from ZIP
   File**. Then select **Browse**, go to **Downloads**, pick **x20-fixes.zip**, and
   confirm the install.

The Quick Access button now works on its own.

### Step 3: Turn on the speakers

1. Open the Quick Access menu → plug icon → **X20 Fixes**.
2. Tap **Apply fix**, and wait for the "Speaker fix applied" message.
3. Tap **Reboot now**.

That's it. After the reboot, X20 Fixes should say **Speakers working**.

## After a SteamOS update

Updates undo the speaker fix. When that happens, X20 Fixes shows a message
after you update. Open it, tap the button it shows (**Apply fix**, or
**Rebuild and apply fix** if SteamOS got a new kernel), then reboot.

To have this happen automatically, turn on **Re-apply after updates** in X20
Fixes. A new kernel still needs the button.

## Removing it

Open X20 Fixes, tap **Remove fix**, and reboot. Then you can uninstall the
plugin from Decky's settings. Uninstalling the plugin alone leaves the speaker
fix in place.

## If something goes wrong

Open X20 Fixes, tap **Show log**, and
[open an issue](https://github.com/ovenham/rog-ally-x20-steamos-speaker-qam-fix/issues)
with what the log and the **Details** section say.

---

*Unofficial, and not affiliated with ASUS, Microsoft or Valve. Use at your own
risk. Tested on a ROG Xbox Ally X20 with BIOS RC74XA.303 and SteamOS kernel
`7.2.7-valve2-1-neptune-72-g31504582a073`.*

The rest of this page is for people who want to know how it works.

## Without Decky (speakers only)

From Desktop Mode, in Konsole:

```
cd speaker-fix
sudo ./ally-audio-fix.sh install     # apply what is needed, then reboot
sudo ./ally-audio-fix.sh status      # show what is active
sudo ./ally-audio-fix.sh uninstall   # remove everything, then reboot
./ally-audio-fix.sh build            # after a kernel update (no sudo)
```

## How it works

### Speakers

The speakers are two TI TAS2783 smart amps on the AMD audio coprocessor's
SoundWire bus. Four separate problems keep them silent:

| Part | Problem | Fix |
|---|---|---|
| **BIOS audio flag** | The ACPI tables set `acp-audio-config-flag = 0x10` ("legacy driver, digital mics only"). Windows ignores it; Linux follows it and skips SoundWire. | A copy of that ACPI table with the flag cleared, loaded at boot as an early initrd ([ACPI table upgrade](https://docs.kernel.org/admin-guide/acpi/initrd_table_override.html)). The BIOS itself isn't modified. |
| **Speaker layout** | Retail units put both amps on SoundWire link 0. The kernel only knows a layout with them on link 1, so it sets up the headset jack and no speakers. | A rebuilt `snd-soc-acpi-amd-match` module with the link-0 layout added ([patch](speaker-fix/patches)), loaded only on the exact kernel it was built for. |
| **Amp tuning** | The amps need TI tuning files, and the X20 ships with one of two speaker suppliers that need different ones. | The script reads the BIOS `SPEAKER_ID` variable and downloads the matching pair from a pinned linux-firmware commit, checking SHA-256 hashes. |
| **Audio profile** | SteamOS's `alsa-ucm-conf` predates TAS2783 support, so PipeWire finds no speaker device. | Upstream's `sof-soundwire/tas2783.conf`, added through an overlay so SteamOS's own profiles stay in use. |

Each part is skipped once SteamOS or the BIOS handles it. If everything has been
fixed upstream, the plugin says the fix can be removed.

### Quick Access button

The Ally's extra buttons come from the controller's ASUS "N-KEY" HID interface
(USB `0b05:1b4c`, the same ID as the Ally X). What each X20 button sends:

| Button | What reaches Linux |
|---|---|
| Xbox | `BTN_MODE` on the gamepad |
| Armoury Crate (top left) | `BTN_MODE` on the gamepad, plus code `0xa6` |
| View (two squares) | `BTN_SELECT` on the gamepad |
| **Quick Access (right side)** | **code `0xa0` only** (`5a a0` on press, `5a 00` on release) |
| Menu | `BTN_START` on the gamepad |

SteamOS's Ally driver doesn't know `0xa0` (the Ally and Ally X use `0xa6` for
Quick Access), so the press is dropped. The plugin reads the interface's raw
reports from hidraw, which every reader gets regardless of which driver owns the
device. When it sees `0xa0`, it opens or closes the Quick Access menu through
Steam's own menu API. It only runs on the X20 (DMI product name `RC74XA`).

`tools/x20-buttons.sh` prints this table for any device: run it with `sudo`
and press buttons during its 10-second capture.

## What gets changed on the system

All of this is removed by *Remove fix* or `ally-audio-fix.sh uninstall`:

| Path | Purpose |
|---|---|
| `/efi/acpi_override.cpio` | The ACPI table with the flag cleared |
| `/efi/EFI/steamos/grub.cfg` | One line per boot entry to load it (original kept as `grub.cfg.pre-ally-audio-fix`) |
| `/var/lib/ally-audio-fix/` | Layout module, amp tuning files, audio-profile overlay, the boot-time helper |
| `/etc/modprobe.d/ally-audio-fix.conf` | Loads the layout module and points the amps at their tuning files |
| `/etc/environment.d/90-ally-audio-fix.conf` | Points the audio system at the profile overlay |
| `~/.local/share/ally-audio-fix/` | Cache of tuning files and rebuilt modules, so re-applying works offline |

Only the active SteamOS slot is changed. Windows (in a dual-boot setup) and the
BIOS are never touched.

## Upstream status

These fixes are workarounds until the real ones land in the kernel and SteamOS:

| Piece | Status |
|---|---|
| BIOS audio flag | Proposed kernel quirk in [`upstream/`](upstream), not yet submitted |
| Speaker layout | Patch in [`speaker-fix/patches/`](speaker-fix/patches), not yet submitted |
| Amp tuning files | In linux-firmware, but under different names than the driver requests ([report](https://ratatoskr.run/linux-sound/2026/08/17413658)) |
| Audio profile | In alsa-ucm-conf since July 2026, not yet in SteamOS |
| Quick Access `0xa0` | Needs mapping in SteamOS's Ally driver; not yet reported |

One note for anyone working on the driver: an upstream proposal gives each mono
amp one channel of the stereo stream
([thread](https://ratatoskr.run/linux-sound/2026/07/17279211/t)). Don't apply it
on the X20, because it silences the right amp. The BIOS's SDCA init table
already assigns each amp its side.

## Repository layout

```
plugin/         Decky plugin (Python backend, TypeScript frontend)
speaker-fix/    ally-audio-fix.sh, kernel patch, prebuilt module, audio profile, tests
tools/          x20-buttons.sh, a button diagnostic
upstream/       proposed kernel patch for the BIOS audio flag
build.sh        builds out/x20-fixes.zip
```

## Development

```
./build.sh                                  # needs Node.js 18+ and Python 3
python3 plugin/tests/qam_test.py            # button watcher
sudo PLUGIN=plugin speaker-fix/tests/run.sh # speaker fix + plugin backend on a simulated X20
```

The speaker tests run the script against a simulated X20 inside a private mount
namespace, so they never touch the real system. They cover install, reboot,
re-install, BIOS updates, uninstall, grub.cfg rollback, SteamOS kernel updates,
and the point where SteamOS catches up. CI runs everything on each push, and
builds and attaches the zip to each published release.

## Credits

- The speaker fix is based on
  [hungarianhc/rog-ally-x20-steamos-speakers](https://github.com/hungarianhc/rog-ally-x20-steamos-speakers),
  which worked out all four problems: the ACPI override, the link-0 layout patch
  and prebuilt module, the speaker-supplier firmware selection, and the UCM
  overlay. This repo extends that script with status checks, update and BIOS
  handling, offline re-apply, rollback on uninstall and tests, and adds the
  Decky plugin and the Quick Access fix.
- `speaker-fix/ucm/tas2783.conf` is from
  [alsa-ucm-conf](https://github.com/alsa-project/alsa-ucm-conf). The amp
  tuning files come from
  [linux-firmware](https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git)
  and are downloaded at install time, not redistributed here.

## License

GPL-2.0-only (see [LICENSE](LICENSE)), except the files listed in
[`LICENSES/`](LICENSES), which are BSD-3-Clause.
