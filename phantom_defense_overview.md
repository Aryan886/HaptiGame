# Phantom Defense — 360° haptics demo

**Implementation handoff for Claude Code and Codex · 28 October 2026**  
**Target:** a reproducible Godot demo in three focused development days.  
**Status:** proposed build specification; game, hardware readiness and perceptual results are not yet verified.

## Decisions recorded 1 November 2026

These supersede conflicting text below.

- No hardware parts exist yet. Claude Code builds `game/`, `bridge/`, `tests/` and reference ESP32 firmware (`firmware/phantom_haptics/`); the game/bridge boundary is unchanged.
- The Godot project lives in `game/`, pinned to **Godot 4.7.2-stable**, Compatibility renderer. This development laptop is the demonstration laptop.
- Default hardware profile: six motors, `H,seq,duration_ms,M1..M6`. Eight motors stay a simulator profile until eight-channel firmware is agreed.
- Haptics keys are **S** (stop) and **E** (enable). Scenarios are on keys **1–5**; key 5 runs a logged direction-identification trial (invisible targets, never revealed; the participant turns and clicks; 8 compass bearings × 3, shuffled; CSV under the Godot user data folder).
- Audio is non-spatial generated tones only. The motor dashboard is toggled with F1 and hidden automatically during the trial.
- `run_demo.bat [simulator|fake|serial]` starts the bridge, then the game. The game never launches the bridge.
- **Damage buzz (changes the spec, agreed in the UI design review).** When a drone reaches the player and removes a health point, every motor buzzes together for about 300 ms at one fixed level (`damage_pulse` in `bridge/config.json`). It carries no direction. It pre-empts the direction cue, which then resumes. The game reports a per-session `damage_count` counter in every snapshot; only the bridge decides motor levels. The pulse obeys the existing safety rules: it starts only while armed and active, never queues while disarmed, and any disarm (S, stale input, protocol error, new session, link reconnect, pause, game over) ends it at once. A round-ending contact holds the game in play with no targets for about 0.5 s so the buzz can finish before the results screen. This replaces the "no global hit vibration" rule in section 6 for damage only; there is still no buzz on a successful shot.
- UI polish (build brief `build_ui.md`): a title screen, a guided demo (1 → 2 → 3 → 4) with intro cards and results screens, a head-shaped haptics widget (F1: off / motors only / full debug), and a practice version of the trial (8 targets, widget visible, true-direction feedback, Shift+5). Trial CSVs gain `practice` and `dashboard_visible` columns. No visual or audio cue reveals a hidden drone's direction.

## 1. Project goal and claim boundary

Build a small **stationary first-person 3D defense game** that makes directional haptics the main interaction. The player stays at the center of an arena, turns the camera with the mouse, feels a cue for a threat outside the view, then finds and shoots it. A moving target demonstrates changing direction; an approaching target demonstrates increasing urgency.

The deliverable is one playable arena, a visible motor dashboard, a separate haptic bridge, and a short repeatable demonstration. Prioritize correct directions, reliable stopping and a clear presentation over graphics or content volume.

**What this demonstrates:** tracking known in-game entities, converting their positions into camera-relative bearings, selecting a threat, and issuing directional motor commands. Physical trials can separately demonstrate whether a wearer distinguishes the cues.

**What this does not establish:** independent microphone-based sound detection, acoustic classification, real-world sound-source localization, or head tracking. Game audio and enemy coordinates come from the same game; reading those coordinates is not detecting sound. An independent acoustic pipeline would need its own sensor input, algorithm, measurements and evaluation outside this three-day scope.

Adjacent-motor interpolation is an experimental output technique. Do not describe a calculated blend as proof of a perceived phantom location or smooth apparent motion. Label the A/B modes **nearest motor** and **interpolated motors**, and record what wearers actually report.

## 2. Decisions, assumptions and scope limits

| Item | Working decision |
|---|---|
| Engine | Godot 4.x with GDScript; record and pin the installed stable version on day 1. No engine migration during the sprint. |
| Platform | One Windows demonstration laptop, keyboard and mouse, ordinary monitor. No VR. |
| Graphics | Primitive meshes, flat materials, simple lighting and a crosshair. Start with the Compatibility renderer; do not depend on glow or expensive effects. |
| Player | Fixed position; unlimited yaw; pitch limited to about ±60°. No walking, jumping or physical body rotation required. |
| Spatial model | Horizontal directions only. Drones stay near camera height. Camera pitch does not change the haptic bearing. |
| Haptic reference | Virtual camera yaw. The wearer faces the screen and uses the mouse to turn the virtual view. There is no measured physical head orientation. |
| Transport | Localhost UDP between Godot and a Python bridge; USB serial from bridge to controller first. Wireless only after the wired path passes. |
| Timeline | Three focused days, assuming available development tools and working or nearly working electronics. This is not a hardware procurement or assembly estimate. |
| Runtime | Game remains playable without the bridge. A bridge in simulator mode supplies motor telemetry without hardware. |
| Persistence | No database, accounts, cloud service or save system. Configuration files and optional local diagnostic logs only. |

### Resolve the motor-count mismatch without coupling the game to hardware

The referenced brainstorm suggested **eight motors**. The current workspace build and purchase notes instead describe **six fitted motors plus two spares**, with six positions at `0, 60, 120, 180, 240, 300` degrees. Eight purchased motors do not imply eight installed channels.

Use the six-position layout as the **provisional hardware profile** and support an eight-position simulator profile at `0, 45, 90, 135, 180, 225, 270, 315` degrees. Confirm the actual fitted count, order, controller and firmware before hardware output. These notes are plans, not evidence that the hardware exists or works.

Keep `motor_angles_deg`, physical channel order, calibration and serial settings in the bridge configuration. Godot sends bearings and draws the motor layout returned by the bridge; it must not hardcode six or eight output channels. The existing notes' Unity choice and longer schedule are superseded for this game by the current Godot, three-day request; their hardware/protocol proposals remain useful integration context.

**Explicitly excluded:** navigation/pathfinding, procedural worlds, multiple weapons, inventory, enemy projectiles, multiplayer, custom character art, machine learning, microphone processing, IMU integration and Bluetooth troubleshooting that delays the core demo.

## 3. Gameplay and demonstration flow

### Core loop

1. Start a 60-second round with three health points and zero score.
2. Spawn simple red drones around the stationary player, including behind and outside the field of view.
3. Update each drone's world position and send a full threat snapshot at 20 Hz.
4. The bridge selects one threat and produces one directional cue, using at most two adjacent motors.
5. The player turns and fires a hitscan laser. One hit destroys a drone and adds one point.
6. An approaching drone reaching the contact radius removes one health point and despawns exactly once.
7. Time expiry or zero health ends the round and clears haptic output. Restart resets all round state.

Start with a spawn radius of `10 m`, contact radius of `1 m`, approach speed of `1.5 m/s`, spawn interval of `3 s`, maximum of `6` live drones and weapon range of `25 m`. These are configurable tuning defaults, not measured optimum values. Add only a small speed increase after the basic loop works; cap difficulty so a new participant can succeed.

### One drone scene, three behaviors

| Behavior | Purpose | Implementation |
|---|---|---|
| `stationary` | Verify fixed directions and motor mapping. | Hold a chosen position until shot or the scenario resets. |
| `approaching` | Demonstrate urgency as distance decreases. | Move directly toward the player on the horizontal plane; no navigation agent. |
| `orbiting` | Demonstrate a changing directional cue. | Move around a fixed-radius circle at a configurable angular speed. |

Use a single behavior enum and small movement functions, not subclasses for each drone. Stationary and orbiting targets are demonstration targets; they have no predicted contact time. The ordinary survival round may use only approaching drones.

### Hidden target mode

Hide the drone's mesh until its absolute horizontal bearing is within `15°` of forward. Keep its collision, movement and event tracking active. Reveal it permanently for that spawn when the player turns close enough; this avoids visibility flicker and makes aiming understandable. A shot may hit a still-hidden collider; a direct hit also resolves the target.

For the controlled showcase, spawn one stationary target behind the player, let the participant orient and destroy it, then run one orbiting target. Use an approaching hidden target only after this works. Disable spatial enemy audio and direction arrows during the haptics-only localization segment so those cues do not supply the answer. Hide the motor dashboard from the participant during that segment; show it separately to explain the result afterward.

### Controls and HUD

| Input action | Default | Behavior |
|---|---|---|
| `shoot` | Left mouse | Fire with a short cooldown; update the ray before checking the hit. |
| `pause` | Escape | Toggle pause and mouse capture; send an inactive snapshot. |
| `restart` | R | Reset the round and begin a new game session ID. |
| `toggle_hidden` | H | Toggle hidden mode and reset its demonstration scenario. |
| `toggle_haptic_mode` | M | Switch nearest/interpolated mapping without changing gameplay. |
| `toggle_debug` | F1 | Show/hide target bearing and motor telemetry. |
| `haptics_stop` | S | Latch haptics off immediately. |
| `haptics_enable` | E | Explicitly enable haptics after startup or a stop. |
| `scenario_1`…`scenario_5` | 1–5 | 1 stationary rear, 2 orbit, 3 hidden approach, 4 survival round, 5 logged direction trial. |

Show health, score, remaining time, crosshair and current mode. Debug view shows selected target ID, bearing, distance, motor positions and commanded levels, bridge status and serial acknowledgement status. Start with haptics disabled. Losing window focus pauses the game and clears output; resuming requires explicit haptics enable.

Do not label a successful UDP send as “hardware connected.” Without fresh bridge telemetry, display **bridge unavailable** and unknown/grey motor indicators. Simulator telemetry must be labelled **simulated output**. Firmware acknowledgement means a command was accepted, not that a motor physically vibrated.

## 4. Minimal architecture, scenes and scripts

```text
Godot world state + yaw-only player orientation
    -> camera-relative threat snapshots (localhost UDP)
Python bridge: validate -> select threat -> map motors -> calibrate
    -> simulator, or serial adapter -> controller -> motors
    -> output telemetry (localhost UDP) -> Godot debug HUD
```

Godot owns gameplay and coordinate conversion. The bridge owns threat arbitration, motor interpolation, calibration and hardware communication. Codex supplies the directional specification and shared numeric fixtures; Claude implements the small Godot-side conversion against those fixtures. Do not implement a second production motor-selection algorithm in the HUD.

This boundary is a deliberate tradeoff: a separate process requires a protocol and freshness checks, but keeps serial libraries, hardware failures and firmware changes out of the game. Direct serial control from Godot would reduce the process count but couple game scripts to the device. Full-state UDP snapshots are chosen for simple local integration and latest-state behavior; they require sequence checks and watchdogs because delivery is not guaranteed.

### Proposed layout if there is no existing Godot project

Inspect the repository first and adapt to its conventions. The current workspace contains planning material, not an existing Godot scene tree. Put a new game under `game/` rather than replacing the workspace contents.

```text
phantom_defense_overview.md
game/
  project.godot
  scenes/
    main.tscn
    player.tscn
    drone.tscn
    hud.tscn
  scripts/
    game.gd
    player.gd
    drone.gd
    haptics_client.gd
    hud.gd
bridge/
  main.py
  haptics.py
  serial_output.py
  config.json
tests/
  direction_cases.json
  test_haptics.py
  verify_directions.gd
readme.md
```

The bridge/tests paths are assigned deliverables, not a request for Claude to duplicate Codex's work. Add a dependency manifest only if needed; use the Python standard library for UDP/JSON/tests and a serial library only at the device boundary. Keep configuration validation next to its use. No generic service framework or dependency injection system is needed.

| Scene or script | Minimum responsibility |
|---|---|
| `main.tscn` + `game.gd` | Arena geometry, lighting, player/HUD instances, enemy container, spawn timing, scenario selection, score, health and round state. Build primitive arena geometry here; no separate arena scene required. |
| `player.tscn` + `player.gd` | `Node3D` yaw root → `Node3D` pitch pivot → `Camera3D` → `RayCast3D`; mouse capture, yaw/pitch and hitscan. Player position stays fixed. |
| `drone.tscn` + `drone.gd` | `Area3D` root with mesh and collision shape; behavior, alive state, hidden/revealed state and one-shot defeat/contact signals. |
| `hud.tscn` + `hud.gd` | `CanvasLayer` with simple controls; update from game signals and bridge telemetry. A custom ring drawn in this script is sufficient. |
| `haptics_client.gd` | A child `Node` of main; snapshot packing, nonblocking UDP polling, input validation for telemetry and freshness status. No serial or motor mapping. |
| `bridge/main.py` | Validate snapshots, maintain session/freshness state, schedule output and return telemetry. Own its event loop; never block Godot. |
| `bridge/haptics.py` | Small testable functions for threat selection, distance strength, circular interpolation and calibrated levels. |
| `bridge/serial_output.py` | Translate complete motor frames into the agreed device protocol, parse acknowledgements and stop on failures. |

Use lowercase `snake_case` for filenames, folders, node names, input actions, JSON keys, functions and variables. Keep Godot built-in type names as documented; use `PascalCase` only if a custom `class_name` is actually useful. Prefer scene references and signals over global singletons. Keep game tuning in exported properties and device tuning in `bridge/config.json`.

**Godot details:** set the ray along local negative Z and enable `collide_with_areas` for `Area3D` drones. Give enemies and arena geometry explicit collision layers; include walls in the ray mask if they should block shots. Call `force_raycast_update()` before consuming a shot result after a camera change because ray results are normally cached between physics updates. Handle no hit and a non-enemy collider without errors. See the official [RayCast3D reference](https://docs.godotengine.org/en/stable/classes/class_raycast3d.html).

Mark a drone dead and disable its collision before emitting defeat/contact signals and freeing it. Remove it from the active registry immediately so shooting, contact and snapshot generation cannot count it twice. Game motion stops while paused, but the haptics client must continue sending inactive snapshots and reading status.

## 5. Version 1 event contract and hardware boundary

Freeze these field names, units, reference frame and shutdown semantics before the two implementations integrate. Changing motor count must not change the game snapshot format.

### A. Godot → bridge: complete threat state

Send one compact UTF-8 JSON object per UDP datagram to `127.0.0.1:9000` at `20 Hz`. Bind the game's telemetry receiver to `127.0.0.1:9001`. Ports are configurable; do not expose either listener to the network by default.

```json
{
  "schema_version": 1,
  "type": "threat_snapshot",
  "session_id": "game_001",
  "seq": 42,
  "source": "game_state",
  "reference_frame": "camera_yaw",
  "game_state": "playing",
  "haptics_enabled": true,
  "haptic_mode": "interpolated",
  "targets": [
    {
      "id": "drone_007",
      "bearing_deg": 90.0,
      "distance_m": 5.0,
      "time_to_contact_s": 2.6667
    }
  ],
  "damage_count": 0
}
```

- `session_id`: fresh opaque ID at launch/restart. IDs shown here are examples. `seq`: increasing nonnegative integer within that session. Do not reuse target IDs within a session.
- `source` and `reference_frame`: exactly `game_state` and `camera_yaw` in this MVP. An acoustic source must not silently enter this stream under the same provenance label.
- `game_state`: `playing`, `paused` or `game_over`. `haptics_enabled`: boolean. `haptic_mode`: `nearest` or `interpolated`.
- `bearing_deg`: finite degrees in `[0, 360)`, clockwise from camera forward. `distance_m`: finite horizontal distance, nonnegative; one Godot world unit is one meter for this project.
- `time_to_contact_s`: finite nonnegative number for a directly approaching target, otherwise JSON `null`. Compute `max(distance_m - contact_radius_m, 0) / approach_speed_mps`; use `null` if speed is zero or the behavior does not approach. Never serialize infinity or NaN.
- `targets` is the entire current set, including hidden and offscreen targets. Empty means no threat; disappearance cancels that target without requiring a separate destroy event.
- `damage_count`: nonnegative integer, health lost so far in this session; 0 at a new session. A missing field means 0; a negative or non-integer value is a protocol error. It is a counter rather than an event flag so a dropped datagram cannot lose a hit. The bridge treats a session's first value as a baseline and buzzes all motors when it rises while armed and active.
- On pause, game over, restart, loss of focus, S (stop) or normal exit, send `haptics_enabled: false` with `targets: []` immediately. Continue inactive snapshots while paused. Exit packets are best effort; watchdogs must handle a crash.

### B. Bridge → Godot: commanded output and status

Return telemetry at up to 20 Hz, including when output is zero. This six-motor example corresponds to the snapshot above under the initial strength rule in section 6, before any non-identity hardware calibration.

```json
{
  "schema_version": 1,
  "type": "motor_state",
  "session_id": "game_001",
  "input_seq": 42,
  "output_backend": "simulator",
  "link_state": "simulated",
  "output_enabled": true,
  "selected_target_id": "drone_007",
  "bearing_deg": 90.0,
  "motor_angles_deg": [0, 60, 120, 180, 240, 300],
  "motor_levels": [0.0, 0.3, 0.3, 0.0, 0.0, 0.0],
  "last_ack_seq": null,
  "pulse_active": false
}
```

`input_seq` echoes the latest accepted game sequence. Ignore telemetry from another game session or an older input sequence. `output_backend` is `simulator`, `serial` or `fake_serial` (in-process firmware model, no hardware); `link_state` is `simulated`, `ready`, `disconnected`, `stale` or `error`. `motor_levels` contains normalized final command values in the same order as `motor_angles_deg`, after calibration and limits; these are not measurements of vibration. For serial output, they correspond to the quantized device values divided by 255. `last_ack_seq` refers to the independent serial command sequence, or is `null` if none is known. It is not a game sequence or a physical sensor reading. `pulse_active` is true while the damage buzz is being commanded; then every level is equal and `selected_target_id` and `bearing_deg` are `null`.

When no target is selected, use `selected_target_id: null`, `bearing_deg: null` and all-zero levels. When the bridge is unavailable, do not retain the last displayed levels as though still active. The bridge supplies the active layout; if it has never connected, show “layout unknown” rather than guessing.

### C. Freshness, validation and failure rules

- Accept only version 1, known message types/enums, finite numeric values, valid booleans, unique target IDs, and bounded data. Start with a `4096-byte` datagram limit and a maximum of `16` targets; gameplay starts at six.
- Drain available packets without blocking; retain the newest valid snapshot rather than accumulating a queue of old cues. Reject duplicate/out-of-order sequences. Invalid packets do not refresh the watchdog; malformed input clears output and logs a useful, rate-limited error.
- Track packet age using the receiver's monotonic clock. After `250 ms` without a newer valid snapshot, clear output and send device STOP. Game HUD treats telemetry older than `250 ms` as unavailable. Do not compare clocks from separate processes for freshness.
- On a new game session, stop, reset selection and sequence state, and require an inactive snapshot followed by an explicit enable before physical output. Retire prior session IDs so delayed old packets cannot switch the bridge back. Support only one game producer at a time.
- Startup, disconnect, timeout, protocol error and reconnect leave physical output disarmed. A fresh disabled→enabled transition after the link is ready is required to resume. Do not replay queued frames. S followed by E is the manual recovery path.
- Check bind/send errors and show actionable status. UDP send success establishes neither a running receiver nor connected hardware; the official [PacketPeerUDP reference](https://docs.godotengine.org/en/stable/classes/class_packetpeerudp.html) describes its connectionless behavior.

### D. Bridge → controller: adapt to the actual firmware

The workspace's proposed six-channel serial protocol already defines newline-terminated ASCII frames:

```text
H,42,150,0,153,0,0,0,0
```

Fields are `H, sequence, duration_ms, M1, M2, M3, M4, M5, M6`. This separate example commands physical M2 at PWM 153 for 150 ms. Values are integers `0–255`, additionally restricted by calibrated caps; all channels replace the previous frame atomically. Array index `0` maps to physical `M1` only when confirmed by the channel map. Every line, including commands below, ends with a newline.

- `HELLO` clears output and starts a new serial sequence session. Send it after connecting and before any nonzero command.
- Device replies (as implemented in `firmware/phantom_haptics/` and `bridge/fake_device.py`): `READY,<N>` after `HELLO` reports the firmware channel count, which the bridge must match; `ACK,<seq>` reports acceptance of serial sequence `seq`; `ERR,<seq or ->,<reason>` reports rejection; `STOPPED` confirms `STOP`.
- `ACK,42` reports acceptance/application of serial sequence 42; `ERR` reports rejection. Keep game and serial sequence counters separate.
- `STOP` clears all outputs immediately and takes precedence over pending frames or acknowledgements.
- Use full frames at no more than 20 Hz. Initial frame duration: `150 ms`; the existing proposal permits `1–500 ms`. Firmware must expire frames locally and also clear outputs after its proposed `500 ms` communication timeout. Invalid or duplicate commands must not extend output duration.
- Confirm the device implements those behaviors on the bench. USB serial is first; reuse the same adapter/protocol over an already functioning Bluetooth serial link only if time allows.

This is a **proposed compatibility target, not verified installed firmware**. Codex and the hardware owner must confirm COM port, baud rate, fitted channels, channel order, acknowledgements and watchdog behavior. An eight-channel firmware variant needs an explicit agreement; do not simply append two values to the six-channel command. Never send an eight-motor simulator frame to six-channel hardware.

Calibration must preserve exact zero as off, use at most two active motors, and respect verified per-channel startup/comfortable limits and the device's total output limit. Do not invent voltage, GPIO or electrical ratings in game code. A physical motor-power stop and firmware-local timeout remain necessary because stopping the host process cannot send a command after it has crashed.

## 6. Directional math, interpolation and threat priority

### Horizontal, camera-relative bearing

Godot's default camera forward is local `-Z`, with `+Y` up. Use the yaw-only player root, not the pitched camera, for the reference axes. See the official [Node3D reference](https://docs.godotengine.org/en/stable/classes/class_node3d.html).

The calculation is:

```text
offset = enemy_position - player_position
offset.y = 0
distance = length(offset)
forward = normalized(-player_yaw.global_basis.z)
right = normalized(player_yaw.global_basis.x)

if distance < 0.001:
    resolve contact or omit the directional target
else:
    direction = offset / distance
    angle = degrees(atan2(dot(direction, right), dot(direction, forward)))
    bearing_deg = positive_mod(angle, 360)
```

Keep the player root unscaled and yaw-only. A target directly above/below the player has no horizontal bearing and is omitted. Do not normalize a zero vector or assign a fictitious front direction. Normal approaching contacts should be resolved before the next snapshot.

| Target relative to the view | Bearing |
|---|---:|
| Front | 0° |
| Front-right | 45° |
| Right | 90° |
| Rear-right | 135° |
| Behind | 180° |
| Rear-left | 225° |
| Left | 270° |
| Front-left | 315° |

With initial camera forward `-Z`, a target at world `+X` is 90°. Turn the camera 90° toward world `+X` and that same target becomes 0°. Camera pitch must not change this result. Do not assume that Godot's raw Y rotation angle increases in the same direction as this clockwise bearing convention.

### Circular motor mapping

For equally spaced `N` motors, let `step = 360 / N`, normalize `theta` into `[0,360)`, then:

```text
position = theta / step
first = floor(position)
second = (first + 1) modulo N
blend = position - first

nearest mode:
    chosen = floor(position + 0.5) modulo N
    level[chosen] = strength

interpolated mode:
    level[first] = strength * (1 - blend)
    level[second] = strength * blend
```

Initialize every other level to zero. Nearest-mode midpoint ties go clockwise. The wrap from the last motor to motor zero must work identically to any other interval. For an uneven calibrated layout, find the two bracketing entries in the sorted circular `motor_angles_deg` list and interpolate over their actual angular gap; do not apply the equal-spacing formula to uneven positions. Keep a channel map if logical angle order differs from wiring order.

Linear command blending is the first implementation because it is easy to inspect and test. Equal-power or psychophysical curves are alternatives for later measured calibration. Neither a constant command sum nor equal numerical levels guarantees constant perceived intensity, especially with ERM startup thresholds.

### Distance strength and selection

Use an initial normalized strength rule before hardware calibration:

```text
strength = clamp(0.2 + 0.8 * (10 - distance_m) / (10 - 0), 0.2, 1.0)
```

Expose near/far distances and minimum/maximum strength in bridge configuration and validate `far > near`. At 10 m the proposed strength is 0.2; at 5 m it is 0.6. No selected target always means exactly zero. Bench calibration determines whether low levels are perceptible and what caps are appropriate.

Select **one** threat to avoid conflicting simultaneous directions:

1. Prefer approaching targets with a non-null time to contact. Pick the smallest time to contact; ties use shorter distance, then stable target ID.
2. If no target is approaching, choose the nearest stationary/orbiting target; ties use stable target ID. A scripted showcase spawns just its intended target so survival enemies cannot steal its cue.
3. Retain the current target unless a same-category challenger is at least 20% more urgent: contact time or distance is `<= 0.8 ×` the current value and strictly smaller. This hysteresis reduces rapid switching.
4. Switch immediately when the current target disappears, an approaching target replaces a non-approaching selection, or a challenger reaches `<= 1 s` to contact while the current selection is outside that emergency window. Among already imminent targets, use the normal retention rule.

Recompute bearing continuously even when the selected target stays the same. Do not mix in global “hit” or recoil vibration during the MVP: HUD feedback is enough, and mixing would obscure the directional cue. If direction smoothing is later needed, smooth across the shortest circular arc, never average 359° and 1° as ordinary numbers. Start without smoothing and tune only from observed jitter.

### Shared fixtures and edge cases

Codex supplies these cases in `tests/direction_cases.json`; both implementations verify the relevant portion. These are required expected results, not claims that a game already passes them.

| Case | Expected result |
|---|---|
| Default yaw; target along `-Z`, `+X`, `+Z`, `-X` | Bearings `0, 90, 180, 270`. |
| Turn view toward world `+X`; target still world `+X` | Bearing `0`, regardless of pitch. |
| Target coincides horizontally with player | Omit directional cue; no NaN or arbitrary angle. |
| Six motors, 30°, strength 0.6 | Indices 0 and 1 each 0.3 before calibration. |
| Six motors, 90°, strength 0.6 | Indices 1 and 2 each 0.3; matches example telemetry. |
| Eight motors, 22.5°, strength 0.6 | Indices 0 and 1 each 0.3. |
| Six motors, 330°, strength 0.6 | Indices 5 and 0 each 0.3. |
| Eight motors, 359°, strength 0.6 | Index 7 approximately 0.013333; index 0 approximately 0.586667. |
| Six motors, 30°, nearest mode | Index 1 only; clockwise tie rule. |
| Current contact time 4 s; challenger 3.5 s, then 3 s | Keep current at 3.5 s; switch at 3 s. |
| Distant approaching target vs nearby stationary target | Approaching target wins under the stated policy. |
| Empty snapshot, pause, dead selected target | Zero output or select another valid target as appropriate. |
| Dropped, duplicate, reordered or malformed packets | No stale replay, no watchdog refresh from invalid/duplicate packets. |
| New session or transport reconnect | Outputs stay off until the fresh disable/enable sequence. |

## 7. Three-day implementation plan

Aim for roughly six focused hours per day, with gameplay and bridge work able to proceed independently after the contract is agreed. Hardware readiness is the largest uncertainty. Do not spend the whole first day on visual polish.

| Day | Claude Code: Godot | Codex + hardware owner: haptics | End-of-day gate |
|---|---|---|---|
| **1 — complete one path** | Inspect project; build primitive arena, stationary view, one drone, shooting and restart. Add bearing calculation, UDP snapshots and minimal status HUD. | Freeze contract and shared fixtures; build simulator, nearest-motor mapping and telemetry. Confirm actual channel profile; test one physical motor over USB and implement stop/watchdogs. | One drone behind/right produces the correct simulated cue; mouse rotation moves its bearing to front; shooting removes the cue. Attempt the first physical end-to-end test today. |
| **2 — finish the demo** | Add approach/orbit behaviors, round loop, hidden target reveal, pause/focus handling and dashboard. | Add interpolation, priority/hysteresis, calibration, full serial output and acknowledgement status. Test disconnect, invalid input and restart. | Complete scripted hidden-target and orbit sequences with simulator; complete wired physical path if hardware is ready. Verify six/eight profiles without changing game code. |
| **3 — freeze and rehearse** | Fix integration bugs, tune readability/difficulty, verify clean startup and export on the demo laptop. | Run directional/transport tests, tune comfortable levels with the wearer, record observed latency and recognition results. | Three consecutive complete rehearsals, a usable export, clear launch instructions and a backup recording. No new feature work. |

**Cut order when behind:** remove extra effects/audio and difficulty progression first, then optional wireless and extra scenarios. Keep one hidden target, one simple orbit scenario if practical, the motor dashboard, nearest mapping and stop behavior. If interpolation is unstable, retain it as a labelled experiment and demonstrate reliable discrete cues. If electronics are not ready by day 2, finish the software simulator and report the physical demo as incomplete; a simulator is a fallback, not proof of hardware success.

Suggested 90-second presentation: explain the provenance/reference frame; enable one hidden rear target; let the participant turn and shoot; run an orbit; show nearest/interpolated output with the dashboard; press stop; state observed results and limitations.

## 8. Acceptance criteria and evidence

### Required software acceptance

- [ ] A fresh checkout/import runs on the pinned Godot version using the documented main scene, without missing assets or script errors.
- [ ] Player translation stays fixed; full yaw rotation, bounded pitch, shooting, no-hit shots, health, timer, score, pause and restart work.
- [ ] Drones spawn around the full circle and all three behaviors work in their designated scenarios. Hidden targets stay tracked while invisible and reveal according to the rule.
- [ ] All cardinal, camera-rotation, zero-distance and motor-wrap fixtures pass. Pitch does not move the haptic bearing.
- [ ] Priority and hysteresis cases pass. Defeated/contacted drones cannot damage, score or emit a stale cue twice.
- [ ] The same Godot build displays six- and eight-motor simulator layouts supplied by the bridge. Hardware-specific values do not appear in gameplay scripts.
- [ ] Missing bridge does not freeze the game; missing hardware leaves a labelled simulator usable. Status distinguishes simulated commands, serial acknowledgement and unavailable output.
- [ ] Empty targets, pause, focus loss, round end, S, process loss, stale input and reconnect are tested. Software freshness stop occurs within 250 ms plus one bridge scheduling tick; firmware expiry is verified separately.
- [ ] Malformed values, NaN/non-finite input, oversized data, duplicate IDs and reordered packets are handled with bounded logging and no nonzero stale output.
- [ ] Run Godot's import/parse check and a short headless start where supported, then manually exercise the rendered game. Run Python tests for priority, interpolation, validation and watchdog behavior. Record commands and results; headless checks do not replace visual or hardware tests.
- [ ] Target 60 FPS with six drones on the demonstration laptop; record the observed result. A five-minute run and three full demo/restart cycles complete without an unhandled error or steadily growing enemy/node count.

### Required to call it an integrated physical demo

- [ ] Actual motor count/order and firmware protocol are recorded and match the bridge profile. Trigger each channel individually and verify its physical position.
- [ ] Game events reach the intended physical channels; all-zero, STOP, disconnect, host crash and firmware expiry behave correctly. At most two channels are active for interpolation.
- [ ] Calibration records usable per-channel settings without claiming identical perceived strength from identical PWM values.
- [ ] Measure event-to-command timing and, if equipment permits, physical onset latency separately. A provisional command-path target is under 100 ms on the demo laptop; label any unmeasured physical latency as unmeasured.
- [ ] Run at least a small randomized direction-identification trial with visual direction cues and enemy audio disabled. Record trial count, true direction, response and errors. Report the observed result without generalizing a small demonstration to validated accuracy.
- [ ] Compare nearest/interpolated modes only after baseline directions work. Record whether the wearer perceives intermediate positions; command logs alone do not satisfy this claim.

Final package: Godot source and export, bridge/configuration, tests and their results, a short `readme.md` with exact startup order/controls/recovery, known limitations, and a backup demonstration recording. Simulator-only completion must be labelled as such.

## 9. Handoff and ownership

| Owner | Owns | Handoff to the other owner |
|---|---|---|
| **Claude Code** | `game/`: scenes, input, gameplay, Godot bearing conversion, snapshot sender, telemetry receiver, HUD and export. | Launch command, pinned Godot version, one captured snapshot, protocol errors encountered and results from shared direction fixtures. |
| **Codex** | `bridge/`: validation, threat priorities, interpolation, configuration, simulator, serial adapter, watchdogs and Python tests; shared numeric fixtures. | Simulator launch command, sample telemetry, hardware profile, protocol fixture cases, dependency/version information and test results. |
| **Hardware owner / team** | Actual assembly, firmware behavior, channel map, power limits, serial configuration, wearable placement and physical trials. | Verified hardware settings, timeout/stop evidence, calibration values and observed wearer responses. Codex may assist with firmware changes when their scope is agreed. |

Agree the contract first, then edit separate owned paths. Keep one versioned contract in this overview or move it to a dedicated protocol document only if it outgrows the overview. Coordinate a contract change before editing both ends; do not independently rename fields or reverse the bearing sign. Share fixtures rather than copying an entire haptic engine into the game.

Before coding a feature, state a 3–5-line approach covering data flow, files and decisions. Inspect existing code first, keep descriptive names and small functions, avoid unnecessary libraries/abstractions, validate inputs, and log or raise errors with context. For non-trivial logic, add meaningful tests or a reproducible verification snippet and run available checks. Summaries should state what works, what was tested and what remains unverified.

## 10. Paste-ready first implementation instruction for Claude Code

```text
Read phantom_defense_overview.md and any applicable AGENTS.md before editing.
Build the first vertical slice of Phantom Defense in Godot 4.x with GDScript.
You own game/; Codex owns the Python haptics bridge and shared math fixtures.

First inspect the workspace and installed Godot version. Reuse an existing
project if present; otherwise create game/ with lowercase snake_case paths.
State the approach in 3–5 lines before writing code, including data flow,
files touched and any decision that would couple the game to hardware.

Implement a primitive arena, fixed-position first-person player, mouse yaw
and clamped pitch, crosshair, raycast shooting, one reusable drone scene,
and a repeatable stationary-target scenario behind or to the right of the
player. Add restart, pause/focus handling, and explicit haptics enable/stop.
Handle drone death/contact only once and keep hidden/offscreen targets in
the threat registry. Start with the stationary behavior; approaching and
orbiting behavior follow once this slice passes.

Implement camera-yaw-relative horizontal bearing exactly as specified.
Send complete version-1 threat_snapshot JSON packets to configurable
localhost port 9000 at 20 Hz. Read motor_state telemetry on port 9001 and
display a small HUD with connection status, bearing and the motor layout
reported by the bridge. Do not hardcode six/eight motors or implement serial,
threat arbitration, calibration or production motor interpolation in Godot.
Without a bridge, keep the game playable and label telemetry unavailable.
Never claim UDP send success means the device is connected.

Send inactive/empty snapshots on pause, focus loss, restart, round end and
stop; keep the communication node processing during pause. Follow the fresh
session and disabled-to-enabled rules. Preserve the separation between
known in-game event tracking and independent sound detection in all labels.

Verify cardinal bearings, camera rotation, pitch independence, zero-distance
handling, raycast miss/hit, repeated restart, no-bridge behavior and immediate
cue removal after destruction. Consume Codex's shared fixtures when available;
otherwise document and run the numeric cases in the overview without changing
the contract. Run available Godot import/parse/headless checks, then a manual
rendered smoke test. Report actual commands/results and any unavailable checks.

Deliver this runnable slice and its launch instructions before adding polish.
Then continue through the day-1 and day-2 game milestones in the overview,
keeping scene logic simple and respecting the stated three-day cut order.
```

## Context and references

- Prior discussion: **Brainstorm Game Ideas**, conversation ID `6ae1b305-0df0-83e8-95e2-2165c1cda62d`. The accepted direction was a minimal stationary 3D game, following an earlier 2D suggestion. This document is self-contained; Claude does not need access to that chat.
- Workspace planning sources: `work/build_team_guide.py` and `work/create_purchase_list.py`, inspected for the six-fitted-motor layout and proposed serial protocol. These generated-document sources describe intentions, not verified hardware state.
- Godot documentation checked for this handoff: [Node3D](https://docs.godotengine.org/en/stable/classes/class_node3d.html), [RayCast3D](https://docs.godotengine.org/en/stable/classes/class_raycast3d.html), [PacketPeerUDP](https://docs.godotengine.org/en/stable/classes/class_packetpeerudp.html). Their stable URLs can change; use documentation matching the version pinned at implementation.

All game tuning values, timing targets and acceptance thresholds above are project choices. They are not measured performance or evidence of perceptual effectiveness.
