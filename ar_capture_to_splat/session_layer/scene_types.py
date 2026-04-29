"""Scene-type taxonomy + stub capture tips for AR-Layer 0.

Each scene type carries a short, generic tip set. Real, scene-specific copy
+ animations land in AR-Layer 1 (the iOS tutorial). Until then this module
is the single source of truth so the iOS app can be built against a stable
list.
"""

from __future__ import annotations

from typing import Any


# Order matters: this is the order the iOS picker will show.
SCENE_TYPES: list[str] = [
    "room",                     # bedroom / living room / office
    "object",                   # tabletop object, ~30 cm scale
    "small_object_turntable",   # tiny object the user rotates in hand / on a turntable
    "corridor",                 # hallway, narrow passage
    "storefront",               # shop interior facing in from the street
    "outdoor_facade",           # building exterior, single side
    "vehicle",                  # car / motorcycle, walk-around
    "large_indoor",             # lobby, atrium, gym, studio
]


# Generic tips (shared baseline). Scene-specific overrides come from
# _SCENE_OVERRIDES below. Keep these short — the iOS UI will animate them.
_BASE_TIPS: list[str] = [
    "Move slowly. Walking pace, not running pace.",
    "Step sideways too. Don't only rotate in place.",
    "Cover near views and far views.",
    "Tilt the phone up, mid, and down.",
    "Revisit corners and occluded areas.",
    "Stop when coverage is full, not when the timer is long.",
]


_SCENE_OVERRIDES: dict[str, list[str]] = {
    "room": [
        "Start in the middle of the room and orbit outward.",
        "Get close to walls, then back away — both distances matter.",
        "Cover the ceiling corners and under any furniture.",
    ],
    "object": [
        "Walk a full circle around the object, twice.",
        "Once at object height, once tilted down at ~45°.",
        "Don't hover — keep moving so each frame is a new view.",
    ],
    "small_object_turntable": [
        "Hold the phone still and rotate the object slowly.",
        "Stop, tilt the phone slightly, rotate again.",
        "Avoid your hand crossing in front of the object.",
    ],
    "corridor": [
        "Walk straight through, then walk back.",
        "Step side-to-side a little while walking.",
        "Don't sprint — slow walk for sharp frames.",
    ],
    "storefront": [
        "Stand at the door, walk inside, sweep left and right.",
        "Capture both shelves and the floor space between them.",
        "Avoid pointing at glare from windows or screens.",
    ],
    "outdoor_facade": [
        "Walk parallel to the wall, full length.",
        "Then a second pass closer in, capturing details.",
        "If sun is harsh, keep it behind you.",
    ],
    "vehicle": [
        "Walk a full circle, knee-height phone first.",
        "Second pass at chest-height, tilted slightly down.",
        "Capture wheels, mirrors, and the underside of bumpers.",
    ],
    "large_indoor": [
        "Move in a wide arc, not a tight circle.",
        "Get the floor and the upper walls in different passes.",
        "Stop briefly in 3–4 spots so tracking can lock.",
    ],
}


def scene_tip_set(scene_type: str) -> dict[str, Any]:
    """Return tutorial-config payload for /tutorial-config endpoint.

    Falls back to the room set with `fallback: true` if scene_type unknown,
    so the iOS app always gets something usable.
    """
    if scene_type in SCENE_TYPES:
        tips = list(_SCENE_OVERRIDES.get(scene_type, [])) + list(_BASE_TIPS)
        return {"scene_type": scene_type, "tips": tips, "fallback": False}
    fallback_tips = list(_SCENE_OVERRIDES["room"]) + list(_BASE_TIPS)
    return {"scene_type": scene_type, "tips": fallback_tips, "fallback": True}
