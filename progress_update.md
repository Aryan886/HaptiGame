# Phantom Defense: progress update

**Date:** 1 November 2026
**Status:** the software works end to end with simulated motor output. No haptics hardware exists yet. The UI polish pass (milestones M1–M4 of `build_ui.md`) is built and tested on branch `ui-polish`; packaging is next.

## Summary

The game, the haptic bridge, the tests and the reference firmware are written and committed. Every automated check passes. In a manual playtest, scenarios 1–4 worked as intended. Scenario 5, the haptics-only direction trial, was hard to play. That's expected for now: it's designed to depend on physical motors, and none are fitted yet.

Every live drone produces a directional cue as soon as it appears, including hidden drones and drones behind the player. The cue reaches the motor output within about 0.1 s and follows the player as they turn. It gets stronger as the drone gets closer, and it stops as soon as the drone is destroyed. At the moment this output is shown on the on-screen motor dashboard; nothing physically vibrates yet.

## Completed

### Game (`game/`, Godot 4.7.2, Compatibility renderer)

- The player stays fixed at the centre of an arena built from simple shapes. The mouse turns the view with unlimited left-right rotation and up-down tilt limited to ±60°. Shooting is instant (hitscan) with a short cooldown.
- One drone type with three movement patterns: stationary, approaching and orbiting. Each drone is destroyed or reaches the player exactly once, so it can't score or cause damage twice.
- Five scenarios on keys 1–5:

  | Key | Scenario | Manual test |
  |---|---|---|
  | 1 | Hidden target (stationary) | Works |
  | 2 | Orbiting target | Works |
  | 3 | Approaching target (hidden) | Works |
  | 4 | 60-second survival round (health, score, timer, gradual speed-up) | Works |
  | 5 | Direction-identification trial (24 invisible targets, logged to CSV) | Works, but can't be played meaningfully without motors |

- Hidden mode: drones are invisible but still tracked, and they appear once the player faces within 15° of them.
- Haptics controls: E enables, S stops immediately, M switches between the nearest motor and two blended (interpolated) motors. Haptics start off and turn off on pause, loss of window focus, restart and game over.
- The HUD shows health, score, time, the current scenario, haptics status and bridge status. An F1 debug dashboard shows the motor ring, commanded motor levels and link details.
- Sound effects are simple generated tones that carry no directional information, so audio can't give away a drone's position.

### Haptic bridge (`bridge/`, Python)

- Checks every incoming update and rejects malformed data: wrong format, impossible numbers, oversized messages or duplicate drone IDs.
- Picks one threat at a time: the soonest approaching drone, otherwise the nearest drone. It holds on to the current threat unless another becomes clearly more urgent, so the cue doesn't flicker between drones.
- Converts a direction into motor levels using the nearest motor or two blended neighbours, with distance-based strength and per-motor calibration limits.
- Safety:
  - **Watchdog:** output stops if the game goes silent for 250 ms.
  - **Explicit re-arming:** output stays off after startup, a new game session, a reconnect or bad input, until haptics are disabled and then enabled again.
  - **Frame mismatch:** the bridge refuses to send 8-motor frames to 6-channel firmware.
- Three output modes: `simulator`, `fake` (the real serial code path against a software model of the firmware) and `serial` for real hardware.
- Motor layouts are set in configuration. Six motors is the default; an eight-motor layout works in the simulator without any game changes.

### Firmware (`firmware/phantom_haptics/`)

- A reference ESP32 sketch implementing the agreed serial protocol. It answers the connection handshake, acknowledges or rejects each command, and supports an immediate stop command. Every command expires on its own, and all outputs switch off if nothing valid arrives for 500 ms.

### Tooling and documentation

- `run_demo.bat` starts the bridge, then the game.
- `readme.md` covers launch, controls, recovery and the steps for bringing up the hardware.
- The decisions from the 1 November review are recorded in the overview.
- The work is in a git repository with milestone commits.

### Test results

| Check | Result |
|---|---|
| Python bridge tests: shared fixtures, input checks, watchdog, sessions, serial path against the fake device, damage pulse | 31 / 31 pass |
| Godot direction checks against the shared fixtures, including that tilting the view up or down doesn't change the direction | 51 / 51 pass |
| Godot gameplay checks: reveal, orbit, damage counted once, pause and focus loss, game over, trial CSV, no leftover drones after restarts, HUD theme, menus and guided demo, F1 widget states, serial defaults, practice trial, CSV columns, damage hold, shot effects | 90 / 90 pass |
| End-to-end game and simulator bridge (including the damage buzz) | Pass |
| End-to-end game and fake serial device (including the damage buzz) | Pass |
| Rendered frame rate, scenario 4 with six live drones, all revealed and on screen, 1280×720, V-Sync off | 167–189 FPS (two runs); 266 FPS with six revealed drones off screen, 349 FPS with six hidden |
| Rendered hidden-drone leak check: a hidden drone 25° off centre and 3 m away vs. the same frame with no drone | Pixel-identical (0 differing pixels); a revealed drone in the same frame differs in about 48,000 pixels |
| Manual playtest of scenarios 1–4 | Working |

## Not yet verified

- Nothing has run on physical hardware yet, and the firmware hasn't been compiled because the ESP32 board package isn't installed.
- No exported executable yet, because the Godot export templates aren't installed. The demo currently runs through the Godot executable.
- A five-minute stability run and three full demo cycles haven't been done. The frame rate with six drones is measured (above).
- The UI polish was checked with headless tests and rendered screenshots, not by a person playing it. A hands-on playthrough of every scenario (especially mouse feel, the projector's colours and the readability of the haptics widget from the back of a room) is still to do.
- pyserial isn't installed. It's only needed once hardware is connected.

## UI polish (done, branch `ui-polish`)

Built to `build_ui.md` in four milestones, each committed with all checks passing. Polish stays within the Compatibility renderer and adds no cue that reveals a hidden drone's direction.

### 1. Menus and flow

- [x] Title screen with the project name, a one-line explanation, and buttons for the guided demo, each scenario and the practice trial (keys 1–5 still work).
- [x] A short intro card for each scenario before it starts: what to do and what the participant should feel.
- [x] A results screen after each scenario or round: outcome, time to find and destroy (1–3), score, time survived and hits (4), error statistics and the CSV path (trial).
- [x] Pause menu with resume, restart, a controls reference and a return to the title screen.
- [x] A persistent amber strip while haptics are off ("HAPTICS OFF · PRESS E"), on every screen.

### 2. HUD

- [x] A consistent visual theme: Chakra Petch (SIL OFL, bundled), a limited palette, and translucent bracketed panels in place of outlined text.
- [x] Health shown as pips, and a segmented timer bar for the survival round.
- [x] Colour-coded status chips for the bridge (simulated output / fake device / hardware ready with the ACK sequence / unavailable / stale).
- [x] A thin bracket crosshair, with an X hit marker on a successful shot (never in the trial).

### 3. Motor dashboard (presenter view)

- [x] A top-down head wearing the headband, with labelled motor positions from the bridge layout and animated intensity.
- [x] F1 cycles off → motors only → full debug. Motors only is the default; on serial hardware the widget starts off in scenarios 1 and 3.
- [x] `practice` and `dashboard_visible` columns in the trial CSV; the real trial forces the widget off.
- [x] A practice version of the trial (8 targets, widget visible, true direction shown after each click).

### 4. Game feel and visuals

- [x] A quadcopter built from primitives (spinning rotors, pulsing red underglow and strip), all of it hidden while the drone is hidden.
- [x] Destruction burst, a 60 ms laser from below the camera, and a symmetric red damage flash on all screen edges.
- [x] Circular night platform with an emissive grid floor, gradient sky, environment fog (verified to render in Compatibility 4.7.2) and identical, evenly spaced pylons.
- [x] Damage buzz: all motors together for about 300 ms when the player loses health (team decision recorded in the overview; built in the bridge, obeys stop/watchdog/arming).

## Next: packaging

- [ ] Install the export templates for Godot 4.7.2 and export `game/export/phantom_defense.exe`.
- [ ] Confirm `run_demo.bat` launches cleanly on the demo laptop.
- [x] Measure FPS with six drones (167–189 FPS, see test results).
- [ ] Run a five-minute session plus three full demo cycles.
- [ ] Record a backup video of the demo.

## Later: hardware integration (once parts arrive)

1. Install the ESP32 board package and pyserial; compile and flash the firmware.
2. Bench-test the serial protocol by hand: the handshake reply, acknowledgements, the stop command and the 500 ms timeout.
3. Trigger each motor on its own, record its physical position and set the wiring map in `bridge/config.json`.
4. With the wearer, set each motor's minimum and comfortable maximum strength.
5. Run the full demo with `run_demo.bat serial`. Then run the direction trial with the dashboard hidden and record the results, comparing nearest-motor and interpolated output.

## Risks and open questions

| Item | Impact | Mitigation |
|---|---|---|
| Hardware arrival date unknown | The physical demo and perception results depend on it | The software path is complete and tested in simulation; integration should need only configuration and calibration |
| Firmware never compiled | Possible build fixes once the toolchain is installed | Logic mirrors the tested software firmware model; compile as soon as the ESP32 board package is installed |
| UI effects could reveal drone direction | Would invalidate haptics-only trials | All new effects stay hidden while a drone is hidden and during the trial; checked with a rendered pixel comparison and the leak checklist in `build_ui.md` |
| Damage buzz could blur the direction cue | The cue pauses for about 300 ms per hit | Agreed as a team; level and duration are in `bridge/config.json`, to be tuned with the wearer |
