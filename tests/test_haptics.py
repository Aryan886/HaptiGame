"""Bridge tests: shared fixtures, validation, selection, watchdog/arming state
machine and the serial path against the fake firmware model.

Run from the repository root:  python -m unittest discover -s tests -v
"""

import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "bridge"))

from fake_device import FakeDevice  # noqa: E402
from haptics import (ProtocolError, Target, map_bearing, parse_snapshot,  # noqa: E402
                     select_target, strength_for_distance)
from main import Bridge, SimulatorOutput, build_output, load_config  # noqa: E402
from serial_output import SerialOutput  # noqa: E402

FIXTURES = json.loads((ROOT / "tests" / "direction_cases.json").read_text(encoding="utf-8"))
CONFIG = load_config(ROOT / "bridge" / "config.json")


class Clock:
    def __init__(self):
        self.t = 100.0

    def __call__(self):
        return self.t


def snapshot(seq, targets=(), enabled=True, session="game_001", state="playing", mode="interpolated", **extra):
    msg = {
        "schema_version": 1, "type": "threat_snapshot", "session_id": session, "seq": seq,
        "source": "game_state", "reference_frame": "camera_yaw", "game_state": state,
        "haptics_enabled": enabled, "haptic_mode": mode, "targets": list(targets),
    }
    msg.update(extra)
    return json.dumps(msg).encode()


DRONE_90 = {"id": "drone_007", "bearing_deg": 90.0, "distance_m": 5.0, "time_to_contact_s": 2.6667}


def make_bridge(profile="six", output=None):
    p = CONFIG["profiles"][profile]
    return Bridge(CONFIG, p, output or SimulatorOutput(len(p["motor_angles_deg"])))


def arm(bridge, now=0.0, session="game_001", start_seq=0):
    bridge.handle_datagram(snapshot(start_seq, enabled=False, session=session), now)
    bridge.handle_datagram(snapshot(start_seq + 1, [DRONE_90], session=session), now)
    return start_seq + 1


class FixtureTests(unittest.TestCase):
    def test_mapping_cases(self):
        for case in FIXTURES["mapping_cases"]:
            with self.subTest(case["name"]):
                levels = map_bearing(case["bearing_deg"], case["motor_angles_deg"], case["strength"], case["mode"])
                self.assertEqual(len(levels), len(case["expected_levels"]))
                for got, want in zip(levels, case["expected_levels"]):
                    self.assertAlmostEqual(got, want, places=5)
                self.assertLessEqual(sum(1 for v in levels if v > 0), 2)

    def test_strength_cases(self):
        for case in FIXTURES["strength_cases"]:
            with self.subTest(case["distance_m"]):
                self.assertAlmostEqual(strength_for_distance(case["distance_m"], 0, 10, 0.2, 1.0), case["expected"])

    def test_selection_cases(self):
        for case in FIXTURES["selection_cases"]:
            with self.subTest(case["name"]):
                targets = [Target(t["id"], t["bearing_deg"], t["distance_m"], t["time_to_contact_s"]) for t in case["targets"]]
                chosen = select_target(targets, case["current_id"])
                self.assertEqual(chosen.id if chosen else None, case["expected_id"])

    def test_hysteresis_sequence(self):
        a = Target("a", 0, 7, 4.0)
        self.assertEqual(select_target([a, Target("b", 90, 6, 3.5)], "a").id, "a")
        self.assertEqual(select_target([a, Target("b", 90, 5, 3.0)], "a").id, "b")

    def test_mapping_is_continuous_across_every_wrap(self):
        for profile in ("six", "eight"):
            angles = CONFIG["profiles"][profile]["motor_angles_deg"]
            for tenth in range(0, 3600):
                levels = map_bearing(tenth / 10, angles, 1.0, "interpolated")
                self.assertAlmostEqual(sum(levels), 1.0, places=9)
                self.assertLessEqual(sum(1 for v in levels if v > 0), 2)


class ValidationTests(unittest.TestCase):
    def assertRejected(self, data):
        with self.assertRaises(ProtocolError):
            parse_snapshot(data)

    def test_valid_snapshot(self):
        snap = parse_snapshot(snapshot(42, [DRONE_90]))
        self.assertEqual(snap.seq, 42)
        self.assertEqual(snap.targets[0].time_to_contact_s, 2.6667)

    def test_rejects_bad_input(self):
        bad_targets = [
            [{**DRONE_90, "bearing_deg": 360.0}],
            [{**DRONE_90, "bearing_deg": -1.0}],
            [{**DRONE_90, "distance_m": -0.1}],
            [{**DRONE_90, "time_to_contact_s": -1}],
            [{**DRONE_90, "bearing_deg": True}],
            [DRONE_90, DRONE_90],
            [{"id": "x"}],
        ]
        for targets in bad_targets:
            with self.subTest(targets):
                self.assertRejected(snapshot(1, targets))
        self.assertRejected(b"not json")
        self.assertRejected(b"\xff\xfe")
        self.assertRejected(b'{"schema_version": 1, "seq": NaN}')
        self.assertRejected(snapshot(1, [{**DRONE_90}]).replace(b"90.0", b"Infinity"))
        self.assertRejected(snapshot(1, schema_version=2))
        self.assertRejected(snapshot(True))
        self.assertRejected(snapshot(-1))
        self.assertRejected(snapshot(1, source="microphone"))
        self.assertRejected(snapshot(1, reference_frame="head"))
        self.assertRejected(snapshot(1, haptic_mode="phantom"))
        self.assertRejected(snapshot(1, [{**DRONE_90, "id": f"d{i}"} for i in range(17)]))
        self.assertRejected(b" " * 5000)


class BridgeStateTests(unittest.TestCase):
    def test_disarmed_until_disabled_then_enabled(self):
        b = make_bridge()
        b.handle_datagram(snapshot(0, [DRONE_90]), 0.0)
        self.assertFalse(any(b.tick(0.0)["motor_levels"]))
        arm(b, 0.01, start_seq=1)
        t = b.tick(0.02)
        self.assertEqual(t["motor_levels"], [0.0, 0.3, 0.3, 0.0, 0.0, 0.0])
        self.assertEqual(t["selected_target_id"], "drone_007")
        self.assertEqual(t["link_state"], "simulated")
        self.assertTrue(t["output_enabled"])

    def test_profiles_change_without_snapshot_change(self):
        b = make_bridge("eight")
        arm(b)
        levels = b.tick(0.0)["motor_levels"]
        self.assertEqual(len(levels), 8)
        self.assertAlmostEqual(levels[2], 0.6)

    def test_watchdog_clears_and_requires_rearm(self):
        b = make_bridge()
        seq = arm(b)
        self.assertTrue(any(b.tick(0.2)["motor_levels"]))
        self.assertFalse(any(b.tick(0.26)["motor_levels"]))
        b.handle_datagram(snapshot(seq + 1, [DRONE_90]), 0.3)
        self.assertFalse(any(b.tick(0.3)["motor_levels"]), "stale recovery must not re-arm by itself")
        arm(b, 0.35, start_seq=seq + 2)
        self.assertTrue(any(b.tick(0.36)["motor_levels"]))

    def test_duplicate_and_reordered_do_not_refresh_watchdog(self):
        b = make_bridge()
        seq = arm(b)
        b.handle_datagram(snapshot(seq, [DRONE_90]), 0.2)
        b.handle_datagram(snapshot(seq - 1, [DRONE_90]), 0.2)
        self.assertFalse(any(b.tick(0.26)["motor_levels"]))

    def test_malformed_clears_output_and_disarms(self):
        b = make_bridge()
        seq = arm(b)
        b.handle_datagram(b'{"broken": ', 0.05)
        self.assertFalse(any(b.tick(0.05)["motor_levels"]))
        b.handle_datagram(snapshot(seq + 1, [DRONE_90]), 0.06)
        self.assertFalse(any(b.tick(0.06)["motor_levels"]))

    def test_new_session_disarms_and_retires_old(self):
        b = make_bridge()
        arm(b, session="game_old")
        b.handle_datagram(snapshot(0, [DRONE_90], session="game_new"), 0.05)
        self.assertFalse(any(b.tick(0.05)["motor_levels"]))
        b.handle_datagram(snapshot(500, [DRONE_90], session="game_old"), 0.06)
        t = b.tick(0.06)
        self.assertEqual(t["session_id"], "game_new")
        self.assertFalse(any(t["motor_levels"]))
        arm(b, 0.07, session="game_new", start_seq=1)
        self.assertTrue(any(b.tick(0.07)["motor_levels"]))

    def test_empty_paused_and_disabled_give_zero(self):
        b = make_bridge()
        seq = arm(b)
        for i, packet in enumerate([snapshot(seq + 1, []), snapshot(seq + 2, [DRONE_90], state="paused"),
                                    snapshot(seq + 3, [DRONE_90], enabled=False)]):
            with self.subTest(i):
                b.handle_datagram(packet, 0.01 * i)
                t = b.tick(0.01 * i)
                self.assertFalse(any(t["motor_levels"]))
                self.assertIsNone(t["selected_target_id"])
                self.assertIsNone(t["bearing_deg"])

    def test_dead_selected_target_switches(self):
        b = make_bridge()
        other = {"id": "drone_008", "bearing_deg": 180.0, "distance_m": 8.0, "time_to_contact_s": 4.6667}
        b.handle_datagram(snapshot(0, enabled=False), 0)
        b.handle_datagram(snapshot(1, [DRONE_90, other]), 0)
        self.assertEqual(b.tick(0)["selected_target_id"], "drone_007")
        b.handle_datagram(snapshot(2, [other]), 0.05)
        self.assertEqual(b.tick(0.05)["selected_target_id"], "drone_008")


PULSE = round(2.0 / 6, 6)  # level 1.0 on six motors, scaled by total_max 2.0


class DamagePulseTests(unittest.TestCase):
    def hit(self, b, seq, now, damage=1, **kw):
        b.handle_datagram(snapshot(seq, [DRONE_90], damage_count=damage, **kw), now)

    def test_increase_while_armed_buzzes_all_then_cue_resumes(self):
        b = make_bridge()
        seq = arm(b)
        self.assertEqual(b.tick(0.0)["motor_levels"], [0.0, 0.3, 0.3, 0.0, 0.0, 0.0])
        self.hit(b, seq + 1, 0.05)
        t = b.tick(0.05)
        self.assertEqual(t["motor_levels"], [PULSE] * 6)
        self.assertTrue(t["pulse_active"])
        self.assertIsNone(t["bearing_deg"], "the pulse carries no direction")
        self.hit(b, seq + 2, 0.2)
        self.assertEqual(b.tick(0.34)["motor_levels"], [PULSE] * 6)
        self.hit(b, seq + 3, 0.34)
        t = b.tick(0.36)
        self.assertFalse(t["pulse_active"])
        self.assertEqual(t["motor_levels"], [0.0, 0.3, 0.3, 0.0, 0.0, 0.0])
        self.assertEqual(t["selected_target_id"], "drone_007")

    def test_increase_while_disarmed_gives_no_pulse(self):
        b = make_bridge()
        b.handle_datagram(snapshot(0, enabled=False), 0.0)
        b.handle_datagram(snapshot(1, enabled=False, damage_count=1), 0.01)
        self.hit(b, 2, 0.02)  # arms with the same count: nothing queued
        t = b.tick(0.02)
        self.assertFalse(t["pulse_active"])
        self.assertEqual(t["motor_levels"], [0.0, 0.3, 0.3, 0.0, 0.0, 0.0])

    def test_first_snapshot_of_session_sets_baseline_only(self):
        b = make_bridge()
        b.handle_datagram(snapshot(0, enabled=False, damage_count=2), 0.0)
        self.hit(b, 1, 0.01, damage=2)
        self.assertFalse(b.tick(0.01)["pulse_active"])
        b.handle_datagram(snapshot(0, enabled=False, session="game_002", damage_count=5), 0.02)
        b.handle_datagram(snapshot(1, [DRONE_90], session="game_002", damage_count=5), 0.03)
        t = b.tick(0.03)
        self.assertFalse(t["pulse_active"], "a new session's first count is a baseline")
        self.assertTrue(any(t["motor_levels"]))

    def test_stop_stale_and_new_session_end_pulse_immediately(self):
        cases = {
            "S": lambda b, seq: b.handle_datagram(snapshot(seq, [DRONE_90], enabled=False, damage_count=1), 0.1),
            "stale": lambda b, seq: None,
            "new session": lambda b, seq: b.handle_datagram(snapshot(0, [DRONE_90], session="game_new", damage_count=1), 0.1),
            "pause": lambda b, seq: b.handle_datagram(snapshot(seq, [DRONE_90], state="paused", damage_count=1), 0.1),
        }
        for name, action in cases.items():
            with self.subTest(name):
                b = make_bridge()
                seq = arm(b)
                self.hit(b, seq + 1, 0.05)
                self.assertTrue(b.tick(0.05)["pulse_active"])
                action(b, seq + 2)
                t = b.tick(0.31 if name == "stale" else 0.1)
                self.assertFalse(t["pulse_active"])
                self.assertFalse(any(t["motor_levels"]))

    def test_rejects_bad_damage_count(self):
        for bad in (-1, 1.5, 1.0, True, "1", None):
            with self.subTest(bad):
                with self.assertRaises(ProtocolError):
                    parse_snapshot(snapshot(1, damage_count=bad))
        self.assertEqual(parse_snapshot(snapshot(1)).damage_count, 0, "missing field means 0")

    def test_disabled_in_config_gives_no_pulse(self):
        config = {**CONFIG, "damage_pulse": {**CONFIG["damage_pulse"], "enabled": False}}
        p = CONFIG["profiles"]["six"]
        b = Bridge(config, p, SimulatorOutput(6))
        seq = arm(b)
        self.hit(b, seq + 1, 0.05)
        self.assertFalse(b.tick(0.05)["pulse_active"])


class SerialPathTests(unittest.TestCase):
    def setUp(self):
        self.clock = Clock()
        self.devices = []

    def open_fake(self, channels=6):
        def factory():
            dev = FakeDevice(channels, clock=self.clock)
            self.devices.append(dev)
            return dev
        return factory

    def serial_bridge(self, channel_map=None, channels=6):
        out = SerialOutput(self.open_fake(channels), 6, channel_map or [0, 1, 2, 3, 4, 5], 150, backend_name="fake_serial")
        b = make_bridge(output=out)
        b.tick(self.clock.t)  # opens the port and sends HELLO
        b.tick(self.clock.t)  # reads READY
        return b, out

    def test_handshake_frames_and_acks(self):
        b, out = self.serial_bridge()
        t = b.tick(self.clock.t)
        self.assertEqual(out.link_state, "ready")
        arm(b, self.clock.t)
        t = b.tick(self.clock.t)
        dev = self.devices[-1]
        self.assertTrue(dev.log[0] == "HELLO")
        self.assertTrue(dev.log[-1].startswith("H,1,150,"))
        self.assertEqual(dev.outputs(), [0, 77, 77, 0, 0, 0])
        self.assertEqual(t["motor_levels"], [0.0, round(77 / 255, 6), round(77 / 255, 6), 0.0, 0.0, 0.0])
        self.clock.t += 0.05
        t = b.tick(self.clock.t)
        self.assertEqual(t["last_ack_seq"], 1)  # frame 2 sent this tick, ACK read next tick
        self.assertEqual(t["link_state"], "ready")

    def test_channel_map_applies_to_physical_order(self):
        b, _ = self.serial_bridge(channel_map=[5, 4, 3, 2, 1, 0])
        b.tick(self.clock.t)
        arm(b, self.clock.t)
        b.tick(self.clock.t)
        self.assertEqual(self.devices[-1].outputs(), [0, 0, 0, 77, 77, 0])

    def test_firmware_channel_mismatch_is_error(self):
        _, out = self.serial_bridge(channels=8)
        self.assertEqual(out.link_state, "error")
        self.assertIn("8 channels", out.last_error)

    def test_stale_input_sends_stop(self):
        b, _ = self.serial_bridge()
        b.tick(self.clock.t)
        arm(b, self.clock.t)
        b.tick(self.clock.t)
        self.clock.t += 0.26
        b.tick(self.clock.t)
        dev = self.devices[-1]
        self.assertEqual(dev.log[-1], "STOP")
        self.assertEqual(dev.outputs(), [0] * 6)

    def test_firmware_expires_frame_without_new_commands(self):
        b, _ = self.serial_bridge()
        b.tick(self.clock.t)
        arm(b, self.clock.t)
        b.tick(self.clock.t)
        dev = self.devices[-1]
        self.assertTrue(any(dev.outputs()))
        self.clock.t += 0.16  # host stops talking (e.g. crashed)
        self.assertEqual(dev.outputs(), [0] * 6)

    def test_firmware_rejects_duplicates_and_bad_frames(self):
        dev = FakeDevice(6, clock=self.clock)
        dev.write(b"H,1,150,0,0,0,0,0,0\n")
        dev.write(b"HELLO\n")
        dev.write(b"H,1,150,0,10,0,0,0,0\n")
        dev.write(b"H,1,500,0,99,0,0,0,0\n")
        dev.write(b"H,2,900,0,99,0,0,0,0\n")
        dev.write(b"H,3,150,0,99,0,0,0\n")
        replies = dev.read(dev.in_waiting).decode().split()
        self.assertEqual(replies, ["ERR,1,no_hello", "READY,6", "ACK,1", "ERR,1,stale_seq",
                                   "ERR,2,out_of_range", "ERR,3,channel_count"])
        self.assertEqual(dev.outputs(), [0, 10, 0, 0, 0, 0])

    def test_reconnect_disarms(self):
        b, out = self.serial_bridge()
        b.tick(self.clock.t)
        arm(b, self.clock.t)
        b.tick(self.clock.t)
        self.devices[-1].close()  # cable pulled
        seq = 2
        for _ in range(60):
            self.clock.t += 0.05
            seq += 1
            b.handle_datagram(snapshot(seq, [DRONE_90]), self.clock.t)
            t = b.tick(self.clock.t)
        self.assertEqual(len(self.devices), 2, "should have reconnected")
        self.assertEqual(t["link_state"], "ready")
        self.assertFalse(any(t["motor_levels"]), "reconnect must not resume output without disable/enable")
        arm(b, self.clock.t, start_seq=seq + 1)
        self.assertTrue(any(b.tick(self.clock.t)["motor_levels"]))

    def test_missing_acks_mark_link_stale(self):
        b, out = self.serial_bridge()
        b.tick(self.clock.t)
        arm(b, self.clock.t)
        b.tick(self.clock.t)
        dev = self.devices[-1]
        dev._reply = lambda text: None  # firmware stops answering
        seq = 2
        for _ in range(12):
            self.clock.t += 0.05
            seq += 1
            b.handle_datagram(snapshot(seq, [DRONE_90]), self.clock.t)
            t = b.tick(self.clock.t)
        self.assertEqual(t["link_state"], "stale")
        self.assertFalse(any(t["motor_levels"]))

    def test_damage_pulse_sends_all_channel_frames(self):
        b, _ = self.serial_bridge(channel_map=[5, 4, 3, 2, 1, 0])
        b.tick(self.clock.t)
        seq = arm(b, self.clock.t)
        b.tick(self.clock.t)
        dev = self.devices[-1]
        self.assertEqual(dev.outputs(), [0, 0, 0, 77, 77, 0])
        self.clock.t += 0.05
        b.handle_datagram(snapshot(seq + 1, [DRONE_90], damage_count=1), self.clock.t)
        t = b.tick(self.clock.t)
        self.assertTrue(dev.log[-1].endswith(",85,85,85,85,85,85"), dev.log[-1])
        self.assertEqual(dev.outputs(), [85] * 6)
        self.assertTrue(t["pulse_active"])
        self.clock.t += 0.3
        b.handle_datagram(snapshot(seq + 2, [DRONE_90], damage_count=1), self.clock.t)
        b.tick(self.clock.t)
        self.assertEqual(dev.outputs(), [0, 0, 0, 77, 77, 0], "direction cue resumes after the pulse")

    def test_refuses_eight_motor_profile_on_six_channel_firmware(self):
        with self.assertRaises(SystemExit):
            build_output(CONFIG, CONFIG["profiles"]["eight"], "fake", None, None)


if __name__ == "__main__":
    unittest.main()
