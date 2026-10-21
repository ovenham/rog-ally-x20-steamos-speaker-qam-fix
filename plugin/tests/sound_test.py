# SPDX-License-Identifier: GPL-2.0-only
#
# Tests the speaker sound filter config (py_modules/sound_boost.py).
# Run from the repo root: python3 plugin/tests/sound_test.py
import json
import os
import re
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "py_modules"))
import sound_boost as sb  # noqa: E402

SINK = "alsa_output.pci-0000_c4_00.5-platform-amd_sdw.HiFi__Speaker__sink"
failures = 0


def check(name, ok, detail=""):
    global failures
    print(("ok   " if ok else "FAIL ") + name + (f": {detail}" if detail and not ok else ""))
    failures += not ok


def node(name, cls="Audio/Sink"):
    return {"type": "PipeWire:Interface:Node", "info": {"props": {"node.name": name, "media.class": cls}}}


# --- finding the speaker sink ---------------------------------------------------------
dump = [
    node("alsa_output.pci-0000_c4_00.1.hdmi-stereo"),
    node("alsa_output.usb-THX_Onyx-00.analog-stereo"),
    node(SINK),
    node("alsa_input.pci-0000_c4_00.5-platform-amd_sdw.HiFi__Mic__source", "Audio/Source"),
    {"type": "PipeWire:Interface:Link", "info": None},
]
check("finds the SoundWire speaker sink", sb.find_speaker_sink(json.dumps(dump)) == SINK)
check("prefers the SoundWire card",
      sb.find_speaker_sink(json.dumps([node("alsa_output.usb-x.HiFi__Speaker__sink"), node(SINK)])) == SINK)
check("no speakers, no sink", sb.find_speaker_sink(json.dumps(dump[:2])) is None)
check("bad pw-dump output", sb.find_speaker_sink("not json") is None)
check("filter not running", not sb.filter_running(json.dumps(dump)))
check("filter running", sb.filter_running(json.dumps(dump + [node(sb.INPUT_NODE)])))

# --- WirePlumber version --------------------------------------------------------------
check("wireplumber 0.5", sb.wireplumber_ok("wireplumber\nCompiled with libwireplumber 0.5.10\nLinked with libwireplumber 0.5.10"))
check("wireplumber 0.4", not sb.wireplumber_ok("wireplumber\nCompiled with libwireplumber 0.4.17\n"))
check("no wireplumber", not sb.wireplumber_ok(""))

# --- the generated config ---------------------------------------------------------------
for level in sb.STRENGTHS:
    conf = sb.conf_text(level, SINK)
    body = re.sub(r'"[^"]*"', '""', "\n".join(ln for ln in conf.splitlines() if not ln.lstrip().startswith("#")))
    check(f"{level}: braces balance", body.count("{") == body.count("}") and body.count("[") == body.count("]"))
    check(f"{level}: targets the speaker sink", f'filter.smart.target = {{ node.name = "{SINK}" }}' in conf)
    check(f"{level}: smart filter", "filter.smart = true" in conf)
    names = re.findall(r"type = builtin name = (\w+) label = (\w+)", conf)
    declared = {n for n, _ in names}
    check(f"{level}: only built-in filters", all(lbl in {
        "copy", "linear", "mixer", "bq_highpass", "bq_lowpass", "bq_peaking", "clamp"} for _, lbl in names))
    used = set(re.findall(r'"(\w+):(?:In(?: \d)?|Out)"', conf))
    check(f"{level}: every link names a declared node", used <= declared, str(used - declared))
    linked_in = set(re.findall(r'input = "(\w+):', conf)) | {"in_l", "in_r"}
    check(f"{level}: every node has an input", declared <= linked_in, str(declared - linked_in))
    trim = sb.STRENGTHS[level]["trim_db"]
    check(f"{level}: turned down to leave headroom", trim <= -4.0)

check("off is a level", sb.LEVELS[0] == "off" and set(sb.LEVELS[1:]) == set(sb.STRENGTHS))
check("unit runs the conf", 'ExecStart=/usr/bin/pipewire -c "/x/sound.conf"' in sb.unit_text("/x/sound.conf"))

# --- writing files as the user ------------------------------------------------------------
with tempfile.TemporaryDirectory() as d:
    path = os.path.join(d, "a", "b", "sound.conf")
    sb.write_user_file(path, "x", os.getuid(), os.getgid())
    check("writes into new directories", open(path).read() == "x")
    sb.write_user_file(path, "y", os.getuid(), os.getgid())
    check("replaces the file", open(path).read() == "y" and not os.path.exists(path + ".tmp"))

print("all passed" if not failures else f"{failures} failed")
sys.exit(1 if failures else 0)
