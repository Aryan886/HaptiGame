"""Pure haptic functions: snapshot validation, threat selection, distance
strength, circular motor mapping and calibration. No I/O."""

from __future__ import annotations

import json
import math
from dataclasses import dataclass
from typing import Optional

GAME_STATES = {"playing", "paused", "game_over"}
HAPTIC_MODES = {"nearest", "interpolated"}


class ProtocolError(ValueError):
    """A datagram that violates the version-1 snapshot contract."""


@dataclass(frozen=True)
class Target:
    id: str
    bearing_deg: float
    distance_m: float
    time_to_contact_s: Optional[float]

    @property
    def approaching(self) -> bool:
        return self.time_to_contact_s is not None


@dataclass(frozen=True)
class Snapshot:
    session_id: str
    seq: int
    game_state: str
    haptics_enabled: bool
    haptic_mode: str
    targets: tuple[Target, ...]
    damage_count: int = 0


# --- validation ---------------------------------------------------------------

def _reject_constant(name: str):
    raise ProtocolError(f"non-finite number {name} is not allowed")


def _is_number(value) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def parse_snapshot(data: bytes, max_bytes: int = 4096, max_targets: int = 16) -> Snapshot:
    if len(data) > max_bytes:
        raise ProtocolError(f"datagram of {len(data)} bytes exceeds {max_bytes}")
    try:
        msg = json.loads(data.decode("utf-8"), parse_constant=_reject_constant)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ProtocolError(f"not valid UTF-8 JSON: {exc}") from None
    return validate_snapshot(msg, max_targets)


def validate_snapshot(msg, max_targets: int = 16) -> Snapshot:
    if not isinstance(msg, dict):
        raise ProtocolError("snapshot is not a JSON object")
    if msg.get("schema_version") != 1 or isinstance(msg.get("schema_version"), bool):
        raise ProtocolError(f"unsupported schema_version {msg.get('schema_version')!r}")
    if msg.get("type") != "threat_snapshot":
        raise ProtocolError(f"unexpected type {msg.get('type')!r}")
    session_id = msg.get("session_id")
    if not isinstance(session_id, str) or not 0 < len(session_id) <= 64:
        raise ProtocolError("session_id must be a non-empty string of at most 64 characters")
    seq = msg.get("seq")
    if not isinstance(seq, int) or isinstance(seq, bool) or seq < 0:
        raise ProtocolError(f"seq must be a nonnegative integer, got {seq!r}")
    if msg.get("source") != "game_state":
        raise ProtocolError(f"unsupported source {msg.get('source')!r}")
    if msg.get("reference_frame") != "camera_yaw":
        raise ProtocolError(f"unsupported reference_frame {msg.get('reference_frame')!r}")
    if msg.get("game_state") not in GAME_STATES:
        raise ProtocolError(f"unknown game_state {msg.get('game_state')!r}")
    if not isinstance(msg.get("haptics_enabled"), bool):
        raise ProtocolError("haptics_enabled must be a boolean")
    if msg.get("haptic_mode") not in HAPTIC_MODES:
        raise ProtocolError(f"unknown haptic_mode {msg.get('haptic_mode')!r}")
    damage_count = msg.get("damage_count", 0)
    if not isinstance(damage_count, int) or isinstance(damage_count, bool) or damage_count < 0:
        raise ProtocolError(f"damage_count must be a nonnegative integer, got {damage_count!r}")
    raw_targets = msg.get("targets")
    if not isinstance(raw_targets, list):
        raise ProtocolError("targets must be a list")
    if len(raw_targets) > max_targets:
        raise ProtocolError(f"{len(raw_targets)} targets exceeds limit of {max_targets}")

    targets = []
    seen = set()
    for i, t in enumerate(raw_targets):
        if not isinstance(t, dict):
            raise ProtocolError(f"target {i} is not an object")
        tid = t.get("id")
        if not isinstance(tid, str) or not 0 < len(tid) <= 64:
            raise ProtocolError(f"target {i} has an invalid id")
        if tid in seen:
            raise ProtocolError(f"duplicate target id {tid!r}")
        seen.add(tid)
        bearing = t.get("bearing_deg")
        if not _is_number(bearing) or not 0 <= bearing < 360:
            raise ProtocolError(f"target {tid}: bearing_deg must be finite in [0, 360), got {bearing!r}")
        distance = t.get("distance_m")
        if not _is_number(distance) or distance < 0:
            raise ProtocolError(f"target {tid}: distance_m must be finite and nonnegative, got {distance!r}")
        ttc = t.get("time_to_contact_s")
        if ttc is not None and (not _is_number(ttc) or ttc < 0):
            raise ProtocolError(f"target {tid}: time_to_contact_s must be null or finite nonnegative, got {ttc!r}")
        targets.append(Target(tid, float(bearing), float(distance), None if ttc is None else float(ttc)))

    return Snapshot(session_id, seq, msg["game_state"], msg["haptics_enabled"], msg["haptic_mode"], tuple(targets),
                    damage_count)


# --- selection ----------------------------------------------------------------

RETAIN_RATIO = 0.8
EMERGENCY_TTC_S = 1.0


def _urgency(t: Target) -> float:
    return t.time_to_contact_s if t.approaching else t.distance_m


def _best(targets) -> Optional[Target]:
    approaching = [t for t in targets if t.approaching]
    if approaching:
        return min(approaching, key=lambda t: (t.time_to_contact_s, t.distance_m, t.id))
    return min(targets, key=lambda t: (t.distance_m, t.id), default=None)


def select_target(targets, current_id: Optional[str]) -> Optional[Target]:
    """Pick one threat with hysteresis; see overview section 6."""
    current = next((t for t in targets if t.id == current_id), None)
    if current is None:
        return _best(targets)
    others = [t for t in targets if t.id != current.id]
    challenger = _best(others)
    if challenger is None:
        return current
    if challenger.approaching and not current.approaching:
        return challenger
    if current.approaching and not challenger.approaching:
        return current
    if (current.approaching and challenger.time_to_contact_s <= EMERGENCY_TTC_S
            and current.time_to_contact_s > EMERGENCY_TTC_S):
        return challenger
    c, n = _urgency(current), _urgency(challenger)
    if n <= RETAIN_RATIO * c and n < c:
        return challenger
    return current


# --- strength and mapping ------------------------------------------------------

def strength_for_distance(distance_m: float, near_m: float, far_m: float,
                          min_strength: float, max_strength: float) -> float:
    if not far_m > near_m:
        raise ValueError("far_m must be greater than near_m")
    fraction = (far_m - distance_m) / (far_m - near_m)
    value = min_strength + (max_strength - min_strength) * fraction
    return max(min_strength, min(max_strength, value))


def map_bearing(bearing_deg: float, motor_angles_deg, strength: float, mode: str) -> list[float]:
    """Levels for motors at ascending angles. Uses the actual gap between the
    two bracketing motors, so uneven layouts interpolate correctly."""
    n = len(motor_angles_deg)
    levels = [0.0] * n
    if n == 0 or strength <= 0:
        return levels
    if n == 1:
        levels[0] = strength
        return levels
    theta = bearing_deg % 360.0
    for i in range(n):
        start = motor_angles_deg[i]
        gap = (motor_angles_deg[(i + 1) % n] - start) % 360.0
        offset = (theta - start) % 360.0
        if offset < gap:
            blend = offset / gap
            second = (i + 1) % n
            if mode == "nearest":
                # Midpoint ties go clockwise.
                levels[second if blend >= 0.5 else i] = strength
            else:
                levels[i] = strength * (1.0 - blend)
                levels[second] += strength * blend
            return levels
    raise AssertionError(f"no bracketing motors for bearing {bearing_deg}")


def calibrate(levels, channel_min, channel_max, total_max: float) -> list[float]:
    """Exact zero stays off; nonzero levels map into each channel's
    [startup, comfortable] range, then the total is capped."""
    out = []
    for level, lo, hi in zip(levels, channel_min, channel_max):
        out.append(0.0 if level <= 0 else lo + (hi - lo) * min(level, 1.0))
    total = sum(out)
    if total > total_max > 0:
        out = [v * total_max / total for v in out]
    return out


def validate_profile(profile: dict, name: str) -> None:
    angles = profile.get("motor_angles_deg")
    if not isinstance(angles, list) or not angles:
        raise ValueError(f"profile {name}: motor_angles_deg must be a non-empty list")
    if any(not _is_number(a) or not 0 <= a < 360 for a in angles):
        raise ValueError(f"profile {name}: every angle must be in [0, 360)")
    if angles != sorted(angles) or len(set(angles)) != len(angles):
        raise ValueError(f"profile {name}: motor_angles_deg must be strictly ascending")
    n = len(angles)
    channel_map = profile.get("channel_map")
    if sorted(channel_map or []) != list(range(n)):
        raise ValueError(f"profile {name}: channel_map must be a permutation of 0..{n - 1}")
    for key in ("channel_min", "channel_max"):
        values = profile.get(key)
        if not isinstance(values, list) or len(values) != n or any(not _is_number(v) or not 0 <= v <= 1 for v in values):
            raise ValueError(f"profile {name}: {key} must list {n} values in [0, 1]")
    if any(lo > hi for lo, hi in zip(profile["channel_min"], profile["channel_max"])):
        raise ValueError(f"profile {name}: channel_min must not exceed channel_max")
    total = profile.get("total_max")
    if not _is_number(total) or total <= 0:
        raise ValueError(f"profile {name}: total_max must be positive")
