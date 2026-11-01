# Phantom Defense: progress update

**Date:** 1 November 2026
**Status:** the software works end to end with simulated motor output. No haptics hardware exists yet. The next phase is UI polish so the demo is ready to present.

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
  | 1 | Hidden stationary target behind the player, to the right | Works |
  | 2 | Orbiting target | Works |
  | 3 | Hidden approaching target | Works |
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
| Python bridge tests: shared fixtures, input checks, watchdog, sessions, serial path against the fake device | 24 / 24 pass |
| Godot direction checks against the shared fixtures, including that tilting the view up or down doesn't change the direction | 51 / 51 pass |
| Godot gameplay checks: reveal, orbit, damage counted once, pause and focus loss, game over, trial CSV, no leftover drones after restarts | 23 / 23 pass |
| End-to-end game and simulator bridge | Pass |
| End-to-end game and fake serial device | Pass |
| Rendered startup | Clean, about 70 FPS with one drone (V-Sync on) |
| Manual playtest of scenarios 1–4 | Working |

## Not yet verified

- Nothing has run on physical hardware yet, and the firmware hasn't been compiled because the ESP32 board package isn't installed.
- No exported executable yet, because the Godot export templates aren't installed. The demo currently runs through the Godot executable.
- Frame rate with six drones and a five-minute stability run haven't been measured.
- pyserial isn't installed. It's only needed once hardware is connected.

## Next: UI polish (priority)

The aim is a demo that looks deliberate and is easy to follow for an audience that has never seen it. Polish must stay within the Compatibility renderer, keep 60 FPS, and never add visual or audio cues that reveal drone direction during haptics-only segments.

### 1. Menus and flow

- [ ] Title screen with the project name, a one-line explanation, and buttons for each scenario plus the trial (keys 1–5 still work).
- [ ] A short intro card for each scenario before it starts: what to do and what the participant should feel.
- [ ] A results screen after each scenario or round: score, time taken, and how long it took to find the target.
- [ ] Pause menu with resume, restart, a controls reference and a return to the title screen.
- [ ] A prominent banner while haptics are off ("Haptics OFF: press E"), so a demo never starts with silent motors.

### 2. HUD

- [ ] A consistent visual theme: one font, a limited colour palette, and semi-transparent panels in place of outlined text.
- [ ] Health shown as icons, and a timer bar for the survival round.
- [ ] Clear status labels for the bridge (simulated / fake device / hardware ready / unavailable) with colour coding.
- [ ] A cleaner crosshair, with a hit marker on a successful shot.

### 3. Motor dashboard (presenter view)

- [ ] Redesign the motor ring for an audience: a body outline viewed from above, labelled motor positions and animated intensity.
- [ ] A "motors only" dashboard mode with no drone-position dots, safe to show during practice.
- [ ] A dashboard-visible column in the trial CSV, so practice runs aren't mistaken for haptics-only results.
- [ ] A practice version of the trial for rehearsing before hardware arrives.

### 4. Game feel and visuals

- [ ] A more distinctive drone built from simple shapes, with a pulsing light (shown only when the drone is revealed).
- [ ] Destruction effect, short muzzle flash and a damage flash at the edges of the screen.
- [ ] Better-looking arena: gradient sky, subtle fog and improved lighting and floor material, all on the Compatibility renderer.
- [ ] Optional: a short non-directional vibration on hit or damage, scheduled so it never overlaps a direction cue. This needs a team decision because the spec currently excludes it.

### 5. Packaging

- [ ] Install the export templates for Godot 4.7.2 and export `game/export/phantom_defense.exe`.
- [ ] Confirm `run_demo.bat` launches cleanly on the demo laptop.
- [ ] Measure FPS with six drones and run a five-minute session plus three full demo cycles.
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
| UI effects could reveal drone direction | Would invalidate haptics-only trials | All new effects stay hidden while a drone is hidden and during the trial |
| Hit or damage vibration (optional) | Could blur the direction cue | Decide as a team before building it |
