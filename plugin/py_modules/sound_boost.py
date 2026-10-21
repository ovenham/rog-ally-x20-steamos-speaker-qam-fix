# SPDX-License-Identifier: GPL-2.0-only
#
# Fuller sound for the X20's internal speakers, from PipeWire's built-in filters only
# (nothing to install; works on stock SteamOS).
#
# On Windows the speakers go through Dolby's processing. Its tuning file for the X20
# has a flat EQ, so what's missing on SteamOS is the "fullness" and width rather than
# a frequency correction (the amps' own TI tuning is the same on both). This chain
# adds three things, more or less of each per strength:
#
#   width      the difference between left and right (above 300 Hz, so the bass
#              stays centred) is mixed back in, which spreads the sound out
#   bass       the bass the small speakers can't play is full-wave rectified, which
#              turns it into its own overtones (2x, 4x the frequency) that they can.
#              The ear fills in the missing fundamental ("virtual bass").
#   body       a broad lift in the low mids, where these speakers still have output
#
# and turns the result down so that the extra energy can't clip. The amps' own
# protection limits excursion either way.
#
# The chain runs in its own PipeWire process (a systemd user unit) as a WirePlumber
# smart filter in front of the speaker sink only, so headphones, USB and Bluetooth
# audio are untouched.

import json
import os
import re

UNIT_NAME = "x20-sound.service"
NODE_BASE = "x20_sound"
INPUT_NODE = f"effect_input.{NODE_BASE}"
OUTPUT_NODE = f"effect_output.{NODE_BASE}"

# width: side signal mixed back in; bass: overtone level; body_db: low-mid lift;
# trim_db: overall level, chosen so a full-scale input still doesn't clip.
STRENGTHS = {
    "light": {"label": "Light", "width": 0.25, "bass": 1.2, "body_db": 3.0, "trim_db": -4.0},
    "full": {"label": "Full", "width": 0.5, "bass": 2.0, "body_db": 5.0, "trim_db": -7.5},
}
LEVELS = ["off", *STRENGTHS]

SIDE_HP_HZ = 300.0     # no widening below this
BASS_LP_HZ = 200.0     # the bass that gets turned into overtones
BASS_HP_HZ = 40.0
OVERTONE_HP_HZ = 160.0  # drops the rectifier's DC and keeps only the overtones
OVERTONE_LP_HZ = 1000.0
BODY_HZ = 380.0
BODY_Q = 0.9

UNIT_TEXT = """# Written by the X20 Fixes Decky plugin ("Speaker sound").
[Unit]
Description=X20 Fixes speaker sound filter
After=pipewire.service wireplumber.service
BindsTo=pipewire.service
ConditionPathExists={conf}

[Service]
Type=simple
ExecStart=/usr/bin/pipewire -c "{conf}"
Restart=on-failure
RestartSec=1
Slice=session.slice

[Install]
WantedBy=default.target
"""


def _db(db: float) -> float:
    return 10.0 ** (db / 20.0)


def _node(kind: str, name: str, control: dict | None = None) -> str:
    ctl = ""
    if control:
        ctl = " control = { " + " ".join(f'"{k}" = {v:.6g}' for k, v in control.items()) + " }"
    return f'{{ type = builtin name = {name} label = {kind}{ctl} }}'


def graph(level: str) -> str:
    """The filter.graph for one strength, as SPA-JSON."""
    p = STRENGTHS[level]
    nodes = [
        _node("copy", "in_l"),
        _node("copy", "in_r"),
        # side = L - R, high-passed; and its negative for the right channel
        _node("linear", "neg_r", {"Mult": -1}),
        _node("mixer", "side"),
        _node("bq_highpass", "side_hp", {"Freq": SIDE_HP_HZ, "Q": 0.707}),
        _node("linear", "side_neg", {"Mult": -1}),
        # bass -> |bass| -> overtones
        _node("mixer", "mono", {"Gain 1": 0.5, "Gain 2": 0.5}),
        _node("bq_lowpass", "bass_lp1", {"Freq": BASS_LP_HZ, "Q": 0.707}),
        _node("bq_lowpass", "bass_lp2", {"Freq": BASS_LP_HZ, "Q": 0.707}),
        _node("bq_highpass", "bass_hp", {"Freq": BASS_HP_HZ, "Q": 0.707}),
        _node("clamp", "pos", {"Min": 0, "Max": 10}),
        _node("clamp", "neg", {"Min": -10, "Max": 0}),
        _node("linear", "neg_flip", {"Mult": -1}),
        _node("mixer", "rect"),
        _node("bq_highpass", "ot_hp1", {"Freq": OVERTONE_HP_HZ, "Q": 0.707}),
        _node("bq_highpass", "ot_hp2", {"Freq": OVERTONE_HP_HZ, "Q": 0.707}),
        _node("bq_lowpass", "ot_lp", {"Freq": OVERTONE_LP_HZ, "Q": 0.707}),
        # sum, low-mid lift, level
        _node("mixer", "sum_l", {"Gain 1": 1, "Gain 2": p["width"], "Gain 3": p["bass"]}),
        _node("mixer", "sum_r", {"Gain 1": 1, "Gain 2": p["width"], "Gain 3": p["bass"]}),
        _node("bq_peaking", "body_l", {"Freq": BODY_HZ, "Q": BODY_Q, "Gain": p["body_db"]}),
        _node("bq_peaking", "body_r", {"Freq": BODY_HZ, "Q": BODY_Q, "Gain": p["body_db"]}),
        _node("linear", "out_l", {"Mult": _db(p["trim_db"])}),
        _node("linear", "out_r", {"Mult": _db(p["trim_db"])}),
    ]
    links = [
        ("in_r:Out", "neg_r:In"),
        ("in_l:Out", "side:In 1"), ("neg_r:Out", "side:In 2"),
        ("side:Out", "side_hp:In"), ("side_hp:Out", "side_neg:In"),
        ("in_l:Out", "mono:In 1"), ("in_r:Out", "mono:In 2"),
        ("mono:Out", "bass_lp1:In"), ("bass_lp1:Out", "bass_lp2:In"), ("bass_lp2:Out", "bass_hp:In"),
        ("bass_hp:Out", "pos:In"), ("bass_hp:Out", "neg:In"), ("neg:Out", "neg_flip:In"),
        ("pos:Out", "rect:In 1"), ("neg_flip:Out", "rect:In 2"),
        ("rect:Out", "ot_hp1:In"), ("ot_hp1:Out", "ot_hp2:In"), ("ot_hp2:Out", "ot_lp:In"),
        ("in_l:Out", "sum_l:In 1"), ("side_hp:Out", "sum_l:In 2"), ("ot_lp:Out", "sum_l:In 3"),
        ("in_r:Out", "sum_r:In 1"), ("side_neg:Out", "sum_r:In 2"), ("ot_lp:Out", "sum_r:In 3"),
        ("sum_l:Out", "body_l:In"), ("body_l:Out", "out_l:In"),
        ("sum_r:Out", "body_r:In"), ("body_r:Out", "out_r:In"),
    ]
    link_text = "\n".join(f'            {{ output = "{o}" input = "{i}" }}' for o, i in links)
    node_text = "\n".join(f"            {n}" for n in nodes)
    return (
        "{\n"
        f"        nodes = [\n{node_text}\n        ]\n"
        f"        links = [\n{link_text}\n        ]\n"
        '        inputs = [ "in_l:In" "in_r:In" ]\n'
        '        outputs = [ "out_l:Out" "out_r:Out" ]\n'
        "    }"
    )


def _q(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"')


def conf_text(level: str, target_sink: str) -> str:
    """A standalone `pipewire -c` config with the filter for one strength."""
    label = STRENGTHS[level]["label"]
    return f"""# Written by the X20 Fixes Decky plugin ("Speaker sound: {label}"). Regenerated on change.
context.properties = {{
    log.level = 2
}}
context.spa-libs = {{
    audio.convert.* = audioconvert/libspa-audioconvert
    support.*       = support/libspa-support
}}
context.modules = [
    {{ name = libpipewire-module-rt
      args = {{ }}
      flags = [ ifexists nofail ]
    }}
    {{ name = libpipewire-module-protocol-native }}
    {{ name = libpipewire-module-client-node }}
    {{ name = libpipewire-module-adapter }}
    {{ name = libpipewire-module-filter-chain
      args = {{
        node.description = "X20 speaker sound ({label})"
        media.name = "X20 speaker sound ({label})"
        filter.graph = {graph(level)}
        audio.channels = 2
        audio.position = [ FL FR ]
        capture.props = {{
            node.name = "{INPUT_NODE}"
            media.class = "Audio/Sink"
            node.link-group = "{NODE_BASE}"
            filter.smart = true
            filter.smart.name = "x20-sound"
            filter.smart.target = {{ node.name = "{_q(target_sink)}" }}
            priority.session = -1
        }}
        playback.props = {{
            node.name = "{OUTPUT_NODE}"
            node.passive = true
            node.link-group = "{NODE_BASE}"
        }}
      }}
    }}
]
"""


def unit_text(conf_path: str) -> str:
    return UNIT_TEXT.format(conf=conf_path)


_SPEAKER = re.compile(r"^alsa_output\..*Speaker", re.IGNORECASE)


def find_speaker_sink(pw_dump_json: str) -> str | None:
    """node.name of the internal speaker sink, from `pw-dump` output."""
    try:
        objects = json.loads(pw_dump_json)
    except ValueError:
        return None
    names = []
    for obj in objects if isinstance(objects, list) else []:
        props = ((obj.get("info") or {}).get("props") or {}) if isinstance(obj, dict) else {}
        name = props.get("node.name")
        if props.get("media.class") == "Audio/Sink" and isinstance(name, str) and _SPEAKER.match(name):
            names.append(name)
    # The X20's speakers sit on the AMD SoundWire card; prefer it if anything else matches.
    names.sort(key=lambda n: "sdw" not in n)
    return names[0] if names else None


def filter_running(pw_dump_json: str) -> bool:
    try:
        objects = json.loads(pw_dump_json)
    except ValueError:
        return False
    for obj in objects if isinstance(objects, list) else []:
        props = ((obj.get("info") or {}).get("props") or {}) if isinstance(obj, dict) else {}
        if props.get("node.name") == INPUT_NODE:
            return True
    return False


def write_user_file(path: str, text: str, uid: int, gid: int) -> None:
    """Write `path` (and missing parent dirs) owned by the user, atomically."""
    d = os.path.dirname(path)
    missing = []
    while d and not os.path.isdir(d):
        missing.append(d)
        d = os.path.dirname(d)
    for m in reversed(missing):
        os.mkdir(m)
        os.chown(m, uid, gid)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.chown(tmp, uid, gid)
    os.replace(tmp, path)


def wireplumber_ok(version_output: str) -> bool:
    """Smart filters need WirePlumber 0.5 or newer."""
    m = re.search(r"libwireplumber\s+(\d+)\.(\d+)|wireplumber\s+(\d+)\.(\d+)", version_output, re.IGNORECASE)
    if not m:
        return False
    major, minor = (int(g) for g in (m.group(1, 2) if m.group(1) else m.group(3, 4)))
    return (major, minor) >= (0, 5)
