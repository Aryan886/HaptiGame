"""Phantom Defense haptic bridge.

Receives version-1 threat_snapshot datagrams from the game, selects one
threat, maps it to motor levels and drives either the simulator or a serial
controller. Returns motor_state telemetry to the game at 20 Hz.

Run:  python bridge/main.py [--backend simulator|serial|fake] [--profile six|eight] [--port COM5]
"""

from __future__ import annotations

import argparse
import json
import logging
import select
import socket
import sys
import time
from pathlib import Path
from typing import Optional

from haptics import (ProtocolError, calibrate, map_bearing, parse_snapshot,
                     select_target, strength_for_distance, validate_profile)
from serial_output import SerialOutput, open_pyserial

log = logging.getLogger("bridge")

TICK_HZ = 20.0


class SimulatorOutput:
    backend_name = "simulator"
    link_state = "simulated"
    ready = True
    link_generation = 1
    last_ack_seq = None

    def __init__(self, channels: int):
        self.levels = [0.0] * channels

    def poll(self, now: float) -> None:
        pass

    def write_levels(self, levels: list[float], now: float) -> list[float]:
        self.levels = list(levels)
        return self.levels

    def stop(self, now: float) -> None:
        self.levels = [0.0] * len(self.levels)

    def close(self) -> None:
        pass


class RateLimitedLog:
    def __init__(self, interval_s: float = 2.0):
        self.interval_s = interval_s
        self._last: dict[str, float] = {}

    def warning(self, key: str, message: str, now: float) -> None:
        if now - self._last.get(key, -1e9) >= self.interval_s:
            self._last[key] = now
            log.warning(message)


class Bridge:
    """Protocol state machine. Pure apart from the injected output backend,
    so tests drive it with explicit timestamps."""

    def __init__(self, config: dict, profile: dict, output):
        self.config = config
        self.profile = profile
        self.output = output
        self.angles = profile["motor_angles_deg"]
        self.timeout_s = config["freshness_timeout_ms"] / 1000.0
        self.limits = config["limits"]
        self.strength_cfg = config["strength"]
        self.pulse_cfg = config["damage_pulse"]
        self.rlog = RateLimitedLog()

        self.session_id: Optional[str] = None
        self.retired: set[str] = set()
        self.last_seq = -1
        self.last_valid: Optional[float] = None
        self.snapshot = None
        self.armed = False
        self.saw_disabled = False
        self.current_target_id: Optional[str] = None
        # Damage pulse: baseline of the session's damage counter, and the end
        # time of a running all-motor buzz (None when no pulse is running).
        self.last_damage_count: Optional[int] = None
        self.pulse_until: Optional[float] = None
        self._seen_link_generation = output.link_generation
        self._output_active = False
        self._last_stop = -1e9

    # --- input ---------------------------------------------------------------
    def handle_datagram(self, data: bytes, now: float) -> None:
        try:
            snap = parse_snapshot(data, self.limits["max_datagram_bytes"], self.limits["max_targets"])
        except ProtocolError as exc:
            self.rlog.warning("protocol", f"rejected snapshot: {exc}", now)
            self.snapshot = None
            self._disarm("protocol error", now)
            return
        if snap.session_id in self.retired:
            return
        if snap.session_id != self.session_id:
            if self.session_id is not None:
                self.retired.add(self.session_id)
            log.info("new game session %s", snap.session_id)
            self.session_id = snap.session_id
            self.last_seq = -1
            self.snapshot = None
            self.current_target_id = None
            self.last_damage_count = None
            self._disarm("new session", now)
        if snap.seq <= self.last_seq:
            return  # duplicate or reordered; does not refresh the watchdog
        self.last_seq = snap.seq
        self.last_valid = now
        self.snapshot = snap
        if not snap.haptics_enabled or snap.game_state != "playing":
            self.saw_disabled = True
            self.armed = False
            self.pulse_until = None
        elif self.saw_disabled and self.output.ready and not self.armed:
            self.armed = True
            log.info("output armed")
        # The first snapshot of a session only sets the baseline; increases
        # while disarmed or inactive update it without queueing a pulse.
        previous, self.last_damage_count = self.last_damage_count, snap.damage_count
        if (previous is not None and snap.damage_count > previous and self.pulse_cfg["enabled"]
                and self.armed and snap.haptics_enabled and snap.game_state == "playing"):
            self.pulse_until = now + self.pulse_cfg["duration_ms"] / 1000.0

    # --- output ----------------------------------------------------------------
    def tick(self, now: float) -> Optional[dict]:
        self.output.poll(now)
        if self.output.link_generation != self._seen_link_generation:
            self._seen_link_generation = self.output.link_generation
            self._disarm("output link (re)connected; disable then enable haptics to resume", now)
        if self.armed and not self.output.ready:
            self._disarm(f"output link {self.output.link_state}", now)
        if self.snapshot is not None and now - self.last_valid > self.timeout_s:
            self.rlog.warning("stale", f"no valid snapshot for {self.timeout_s * 1000:.0f} ms; output cleared", now)
            self.snapshot = None
            self._disarm("stale input", now)

        snap = self.snapshot
        active = self.armed and snap is not None and snap.haptics_enabled and snap.game_state == "playing"
        target = select_target(snap.targets, self.current_target_id) if active else None
        self.current_target_id = target.id if target else None
        pulse = active and self.pulse_until is not None and now < self.pulse_until
        if not pulse:
            self.pulse_until = None
        else:
            target = None  # the pulse pre-empts the direction cue; selection state is kept

        commanded = [0.0] * len(self.angles)
        if pulse:
            # Every motor at one fixed level: no direction. Calibration and
            # total_max still apply.
            levels = calibrate([self.pulse_cfg["level"]] * len(self.angles), self.profile["channel_min"],
                               self.profile["channel_max"], self.profile["total_max"])
            sent = self.output.write_levels(levels, now)
            if sent is not None:
                commanded = sent
                self._output_active = True
        elif target is not None:
            s = self.strength_cfg
            strength = strength_for_distance(target.distance_m, s["near_m"], s["far_m"], s["min"], s["max"])
            levels = map_bearing(target.bearing_deg, self.angles, strength, snap.haptic_mode)
            levels = calibrate(levels, self.profile["channel_min"], self.profile["channel_max"], self.profile["total_max"])
            sent = self.output.write_levels(levels, now)
            if sent is not None:
                commanded = sent
                self._output_active = True
        if not any(commanded):
            if self._output_active or now - self._last_stop >= 1.0:
                self.output.stop(now)
                self._last_stop = now
            self._output_active = False

        if self.session_id is None:
            return None
        return {
            "schema_version": 1,
            "type": "motor_state",
            "session_id": self.session_id,
            "input_seq": max(self.last_seq, 0),
            "output_backend": self.output.backend_name,
            "link_state": self.output.link_state,
            "output_enabled": self._output_active,
            "selected_target_id": target.id if target else None,
            "bearing_deg": target.bearing_deg if target else None,
            "motor_angles_deg": self.angles,
            "motor_levels": [round(v, 6) for v in commanded],
            "last_ack_seq": self.output.last_ack_seq,
            "pulse_active": pulse,
        }

    def _disarm(self, reason: str, now: float) -> None:
        if self.armed:
            log.info("output disarmed: %s", reason)
        self.armed = False
        self.saw_disabled = False
        self.pulse_until = None
        if self._output_active:
            self.output.stop(now)
            self._last_stop = now
        self._output_active = False


# --- configuration -------------------------------------------------------------

def load_config(path: Path) -> dict:
    with open(path, encoding="utf-8") as f:
        config = json.load(f)
    for name, profile in config["profiles"].items():
        validate_profile(profile, name)
    s = config["strength"]
    if not s["far_m"] > s["near_m"]:
        raise ValueError("strength.far_m must be greater than strength.near_m")
    if not 0 <= s["min"] <= s["max"] <= 1:
        raise ValueError("strength min/max must satisfy 0 <= min <= max <= 1")
    pulse = config["damage_pulse"]
    if not isinstance(pulse["enabled"], bool) or not pulse["duration_ms"] > 0 or not 0 < pulse["level"] <= 1:
        raise ValueError("damage_pulse needs enabled (bool), duration_ms > 0 and 0 < level <= 1")
    return config


def build_output(config: dict, profile: dict, backend: str, port: Optional[str], baud: Optional[int]):
    channels = len(profile["motor_angles_deg"])
    if backend == "simulator":
        return SimulatorOutput(channels)
    serial_cfg = config["serial"]
    firmware_channels = serial_cfg["firmware_channels"]
    if channels != firmware_channels:
        raise SystemExit(f"profile has {channels} motors but firmware is configured for {firmware_channels} channels; "
                         "refusing to send mismatched frames to hardware")
    if backend == "fake":
        from fake_device import FakeDevice
        open_port = lambda: FakeDevice(channels)  # noqa: E731
        name = "fake_serial"
    else:
        port = port or serial_cfg["port"]
        baud = baud or serial_cfg["baud"]
        open_port = lambda: open_pyserial(port, baud)  # noqa: E731
        name = "serial"
    return SerialOutput(open_port, channels, profile["channel_map"], serial_cfg["frame_duration_ms"],
                        backend_name=name, ready_timeout_s=serial_cfg["ready_timeout_ms"] / 1000,
                        ack_timeout_s=serial_cfg["ack_timeout_ms"] / 1000)


def _disable_udp_connreset(sock: socket.socket) -> None:
    # Windows reports ICMP port-unreachable as ConnectionResetError on later recv calls.
    if hasattr(socket, "SIO_UDP_CONNRESET"):
        sock.ioctl(socket.SIO_UDP_CONNRESET, False)


def run(args) -> int:
    config = load_config(Path(args.config))
    profile_name = args.profile or config["active_profile"]
    profile = config["profiles"][profile_name]
    output = build_output(config, profile, args.backend or config["output_backend"], args.port, args.baud)
    bridge = Bridge(config, profile, output)

    net = config["network"]
    listener = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        listener.bind((net["listen_host"], net["listen_port"]))
    except OSError as exc:
        log.error("cannot bind %s:%d (%s); is another bridge running?", net["listen_host"], net["listen_port"], exc)
        return 1
    listener.setblocking(False)
    _disable_udp_connreset(listener)
    sender = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    _disable_udp_connreset(sender)
    telemetry_addr = (net["telemetry_host"], net["telemetry_port"])

    log.info("bridge listening on %s:%d, telemetry to %s:%d, backend %s, profile %s %s",
             net["listen_host"], net["listen_port"], *telemetry_addr, output.backend_name,
             profile_name, profile["motor_angles_deg"])
    if output.backend_name != "serial":
        log.info("no hardware: output is %s", "simulated" if output.backend_name == "simulator" else "a fake serial device")

    period = 1.0 / TICK_HZ
    next_tick = time.monotonic()
    next_status = next_tick
    try:
        while True:
            now = time.monotonic()
            readable, _, _ = select.select([listener], [], [], max(0.0, next_tick - now))
            if readable:
                while True:
                    try:
                        data, _ = listener.recvfrom(65535)
                    except (BlockingIOError, ConnectionResetError):
                        break
                    bridge.handle_datagram(data, time.monotonic())
            now = time.monotonic()
            if now >= next_tick:
                next_tick = max(next_tick + period, now)
                telemetry = bridge.tick(now)
                if telemetry is not None:
                    try:
                        sender.sendto(json.dumps(telemetry, separators=(",", ":")).encode(), telemetry_addr)
                    except OSError as exc:
                        bridge.rlog.warning("send", f"telemetry send failed: {exc}", now)
                if now >= next_status:
                    next_status = now + 1.0
                    _print_status(bridge, telemetry)
    except KeyboardInterrupt:
        log.info("stopping")
    finally:
        output.stop(time.monotonic())
        output.close()
        listener.close()
        sender.close()
    return 0


def _print_status(bridge: Bridge, telemetry: Optional[dict]) -> None:
    if telemetry is None:
        log.info("waiting for game snapshots (link %s)", bridge.output.link_state)
        return
    levels = " ".join(f"{v:.2f}" for v in telemetry["motor_levels"])
    log.info("seq %d  link %s  armed %s  target %s  bearing %s  levels [%s]  ack %s",
             telemetry["input_seq"], telemetry["link_state"], bridge.armed, telemetry["selected_target_id"],
             telemetry["bearing_deg"], levels, telemetry["last_ack_seq"])


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--config", default=str(Path(__file__).with_name("config.json")))
    parser.add_argument("--backend", choices=["simulator", "serial", "fake"])
    parser.add_argument("--profile", help="profile name from config.json, e.g. six or eight")
    parser.add_argument("--port", help="serial port, e.g. COM5")
    parser.add_argument("--baud", type=int)
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s", datefmt="%H:%M:%S")
    try:
        return run(args)
    except (ValueError, KeyError) as exc:
        log.error("configuration error: %s", exc)
        return 2


if __name__ == "__main__":
    sys.exit(main())
