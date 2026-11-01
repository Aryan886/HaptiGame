# Build brief: Phantom Defense UI polish

**Agreed:** 1 November 2026, in a design review with the project owner.
**Use:** a fresh Claude Code session reads this file, then implements it milestone by milestone.
**Scope:** section "Next: UI polish" of [progress_update.md](progress_update.md). Everything below supersedes that checklist where they differ.

## 0. Before writing code

1. Read [progress_update.md](progress_update.md), [readme.md](readme.md), and the "Decisions recorded 1 November 2026" section of [phantom_defense_overview.md](phantom_defense_overview.md).
2. Read these files in full: `game/scripts/game.gd`, `game/scripts/hud.gd`, `game/scripts/drone.gd`, `game/scripts/haptics_client.gd`, `bridge/main.py` (`Bridge.handle_datagram`, `Bridge.tick`), `bridge/haptics.py` (`validate_snapshot`, `calibrate`), `tests/game_checks.gd`, and `tests/test_haptics.py`.
3. Run all checks (section 7) and confirm they pass before changing anything.
4. Work one milestone at a time. At the end of each milestone, all checks pass and the work is committed. Don't start the next milestone in the same commit.
5. If a decision below turns out to be impossible or harmful (for example, a renderer limitation), stop and ask the owner. Don't silently substitute something else.

## 1. Hard constraints (never break these)

- **Renderer:** Godot 4.7.2-stable, Compatibility renderer, at least 60 FPS with 6 live drones at 1280×720. Don't depend on glow, SSAO, SDFGI or volumetric fog. Check what Compatibility actually supports in 4.7.2 before using a feature.
- **No direction leaks:** never add a visual or audio cue that reveals a drone's direction while it's hidden, or at any point during the trial. That covers:
  - text that names a direction (on intro cards, scenario names or captions)
  - directional damage indicators
  - spatial audio
  - lights, shadows, particles or rotor motion from hidden drones
  - edge flashes that are stronger on one side than another
- **Safety rules unchanged:** haptics start off and stay off until E. S stops immediately. The bridge's watchdog, arming, re-arming and frame-mismatch rules must stay exactly as they are. New output (the damage buzz) obeys all of them.
- **Honest status labels:** never label a UDP send as "hardware connected". Simulated output is labelled as simulated. A firmware ACK means the command was accepted, not that a motor vibrated.
- **Game/bridge boundary:** the game reports state and events. Only the bridge decides motor levels. The HUD draws telemetry and never computes motor output.
- **Keys:** keys 1–5, E, S, M, H, R, F1 and Esc keep working everywhere they work today.
- **Style of the code:** match the existing code. UI is built in GDScript (no hand-written `.tres` themes unless needed), with sparse doc comments.

## 2. Agreed design decisions

| Area | Decision |
|---|---|
| Audience | Assessors and lecturers. One laptop screen mirrored to a projector, so everything stays in one window. |
| Visual style | Tactical sci-fi HUD: dark arena, cyan line work and panels, amber for warnings, red for threats. Thin-line, semi-transparent panels with corner brackets instead of outlined text. |
| Font | One SIL OFL family bundled in `game/fonts/` with its `OFL.txt`. Default: **Chakra Petch** (Regular + SemiBold or Bold) from the google/fonts repository. If you can't download it, stop and ask; don't fall back silently. |
| Explanatory UI | Intro cards only. No "how it works" screen, no live captions, no interpretation text on results screens. |
| Flow | Title screen → "Start guided demo" runs 1→2→3→4 (intro card → play → results → Next). A scenario list allows free selection. Keys 1–5 still start scenarios directly (skipping the intro card is fine). |
| HUD layout | Top bar: scenario name, health pips, a timer bar (survival only) and the score. Bottom-left: haptics and bridge status chips. Bottom-right: the haptics widget. The centre stays clear. |
| Haptics off | A persistent amber strip below the top bar, "HAPTICS OFF · PRESS E", whenever haptics are off: on the title screen, intro cards and during play. It never blocks anything. |
| Haptics widget | A top-down **head** (the wearable is a headband) with a nose/front marker and the motors from telemetry `motor_angles_deg` drawn around it. Motor size and glow animate with the commanded level. |
| F1 | Cycles **off → motors only → full debug** (full debug adds the drone dots and telemetry text from today's panel). The default is motors only. |
| Widget in hidden scenarios | In scenarios 1 and 3, the widget defaults to **off** when telemetry `output_backend == "serial"`, and to **motors only** for `simulator` and `fake_serial`. F1 still overrides it. In the real trial it is forced off (as today). |
| Damage buzz | **This changes the spec.** When a drone reaches the player and removes a health point, all motors buzz together for about 300 ms at one fixed level. The buzz pre-empts the direction cue, then the cue resumes. Built in the bridge (section 5). |
| Practice trial | 8 targets (one per bearing, shuffled), widget visible (motors only), and after each click it shows the true direction against the answer. Started from the title screen ("Direction trial · practice") and Shift+5. |
| Trial CSV | New columns `practice` and `dashboard_visible` (whether the widget was visible when the response was made). |
| Drone | A quadcopter from primitives: flat body, four arms, four rotor discs spinning, red underglow light plus a pulsing emissive strip. All of it is visible only when revealed. One look for every behaviour. |
| Arena | A circular night defence platform: emissive grid floor (cheap shader), dark gradient sky, light distance fog, evenly spaced perimeter pylons in a repeating pattern. No unique landmark that could line up with a target. |
| Hit/damage visuals | Crosshair hit marker on a successful shot; short muzzle flash or laser; destruction burst at the drone (it's resolved, so no leak); **uniform** red flash on all screen edges when the player takes damage. |

## 3. Milestones

### M1: theme and HUD

Build:

- Add the font and a single theme helper (for example `game/scripts/ui_theme.gd`) with the palette constants, font sizes, a panel StyleBox factory and a status-chip factory. Every later screen uses it.
  - Suggested palette: background panel `#0B1220` at about 75% alpha, line cyan `#38E1FF`, dim cyan `#1F6F86`, amber `#FFB020`, threat red `#FF3B3B`, ok green `#3DDC84`, text `#E6F1F5`, muted `#8AA0AD`. Tune these on the projector if needed.
- Rebuild `hud.gd` to the agreed layout:
  - Top bar: scenario name, health pips (filled or empty), score, and a timer bar with the seconds left in scenario 4.
  - Bottom-left: the haptics chip (ON green / OFF amber) plus the output mode (NEAREST / BLEND), and the bridge chip.
  - The amber HAPTICS OFF strip.
- Bridge chip states, mapped from `haptics_client.status_text()` and telemetry:

  | State | Colour |
  |---|---|
  | SIMULATED OUTPUT | cyan |
  | FAKE DEVICE (NO HARDWARE) | cyan |
  | HARDWARE READY · ACK n | green |
  | BRIDGE UNAVAILABLE | red |
  | stale / socket error | grey, with "?" |

- Change the display names in `SCENARIO_NAMES` so none of them gives away a direction ("1 stationary rear" currently does). For example: 1 Hidden target, 2 Orbiting target, 3 Approaching target, 4 Survival, 5 Direction trial.
- New crosshair (thin bracket style), with an X hit marker that flashes on a successful hit. No hit marker in the trial, where clicks are responses.

Done when:

- All text uses the bundled font.
- No outlined labels remain.
- The existing F1 panel still works; it gets restyled in M3.
- The checks pass.

### M2: menus and flow

Build:

- Add a front-end state in `game.gd`: `title`, `intro`, `playing`, `paused`, `results`, `game_over`.
  - The bridge only accepts the game states `playing` / `paused` / `game_over`. Send `paused` (inactive, no targets) for title, intro and results. Don't change the bridge's `GAME_STATES` for this.
  - Mouse is visible in menus and captured in play.
- **Title screen:**
  - "PHANTOM DEFENSE" and the one-liner "Find what you can't see."
  - Buttons: Start guided demo; the scenario list 1–5; "Direction trial · practice".
  - The status chips stay visible.
- **Intro card:** shown before each scenario in the guided demo and when one is started from the title screen. Draft copy is below and can be refined, but it must stay direction-free.

  | Scenario | Do | Feel |
  |---|---|---|
  | 1 | "A drone is hiding somewhere around you. Turn until you find it, then shoot." | "A steady buzz on one side of your head. It moves to your forehead as you face the drone." |
  | 2 | "A drone is circling you. Follow it and shoot." | "The buzz travels around your head." |
  | 3 | "An unseen drone is closing in. Find it before it reaches you." | "The buzz grows stronger as it gets closer. If it reaches you, every motor buzzes at once." |
  | 4 | "Drones come from all sides for 60 seconds. You can take 3 hits." | "The buzz points to the most urgent drone. Every motor buzzing at once means you were hit." |
  | 5 | "Turn toward the vibration and click. Targets never appear." | "One buzz per target." |
  | Practice | As 5. | As 5, plus "After each click you'll see the true direction." |

  Buttons: Start (Enter/click) and Back.
- **Results screen** (replaces the current text `message` for completion and game over):

  | Scenario | Stats |
  |---|---|
  | 1–3 | Outcome; time to find (spawn → first reveal within the 15° cone); time to destroy (spawn → defeat) |
  | 4 | Score, time survived, hits taken |
  | 5 / practice | Responses, mean absolute error, number within 22.5°, CSV path |

  Buttons: Next (guided demo only; after 4 it reads "Finish" and returns to the title screen), Retry, Title.
  You'll need to add timestamps for spawn and first reveal. Keep them in `game.gd` or on the drone.
- **Pause menu (Esc):** Resume, Restart, Controls (the key table from readme.md), Title. Pausing still sends an inactive snapshot, as today.
- Update `tests/game_checks.gd`. It currently relies on `_ready()` starting scenario 1 (`game.drones["drone_001"]`). Have the test start scenario 1 explicitly, and add checks for:
  - title → intro → playing
  - pause → title clears the drones and sends inactive
  - completing scenario 1 in the guided demo leads to results, and Next starts scenario 2

Done when the whole guided demo can be clicked through without touching keys 1–5, and the checks pass.

### M3: haptics widget, damage buzz, practice trial

Build:

- Replace `RingView` with the head widget:
  - A bottom-right panel of about 20% of screen height in the theme style.
  - A top-down head with a nose wedge at the top (screen up = camera forward, as today).
  - Motors placed from `motor_angles_deg`; each one's radius and glow lerp with its level, and its index is labelled (M1…).
  - Footer: backend label + NEAREST/BLEND.
  - Unknown layout or stale telemetry: grey motors with "?", as today.
- F1 three-state cycle and the serial-dependent defaults in hidden scenarios (section 2). The full-debug state adds today's drone dots, bearing line and telemetry text in a panel above the widget.
- Damage buzz: see section 5 for the protocol and bridge work. In the widget, show the buzz as all motors lit together. That carries no direction, so it's fine to show.
- Practice trial: a `practice` flag on the existing trial path; don't add a sixth scenario enum unless that's clearly simpler.
  - 8 bearings, each once, shuffled.
  - Widget forced to motors only.
  - Feedback during the gap after each click: a small dial over the widget showing the true bearing and the answer (and the signed error), cleared before the next target spawns. The gap may need to be longer.
- Trial CSV: add `practice` and `dashboard_visible` columns. Update the header and `_write_trial_row`. The real trial must always write `dashboard_visible=false`; add a check for it.

Done when the bridge tests (including the new buzz tests) pass, the game checks cover the F1 cycle, the serial defaults, the practice CSV columns, and the real trial with `dashboard_visible=false`, and the end-to-end smoke test passes.

### M4: drone, effects, arena

Build:

- **Drone:** rebuild `drone.tscn` as a quadcopter under a single `visual` Node3D.
  - Hiding and revealing toggles `visual.visible`, which must hide every mesh, light and particle and their shadows.
  - Keep the collision shape the same size, or make sure the hit tests still pass.
  - Keep a `mesh` property or update the tests that read `d.mesh.visible`.
  - Rotor spin runs on the visual only.
  - Revealed drones get the pulsing underglow (an OmniLight3D with a small range and an emissive strip). Watch the Compatibility per-object light limits.
- **Effects:**
  - Destruction burst: CPUParticles3D, short.
  - Muzzle flash or laser line from just below the camera to the hit point, about 60 ms.
  - Damage flash: a full-rect ColorRect with a radial vignette shader, uniform on all edges, about 300 ms.
  - Nothing spawns at a hidden drone's position except the destruction burst after a defeat (by then it's resolved).
  - In the trial there are no shot effects at all, only the neutral click tone.
- **Arena** (replace `_build_arena`):
  - Circular platform about 24 m across with a grid shader (emissive cyan lines, dark base).
  - Sky: ProceduralSkyMaterial or a gradient shader.
  - Environment fog if Compatibility supports it in 4.7.2; otherwise a fog-coloured horizon ring or fade.
  - Evenly spaced identical pylons with small cyan caps.
  - Better floor material and lighting.
- Measure FPS with 6 drones in scenario 4 (rendered, V-Sync off for the measurement) and record the number in the progress report.

Done when there's no FPS regression below 60 and the checks pass. Then do a manual rendered playthrough of all scenarios and confirm hidden drones show nothing: no light, shadow or particles.

### After M4: packaging (from progress_update.md, unchanged)

Install the export templates, export `game/export/phantom_defense.exe`, test `run_demo.bat`, run the 5-minute stability test, and record the backup video. Some of this needs the owner (installing templates, recording the video). Ask, rather than assuming.

## 4. File impact (expected)

- `game/scripts/hud.gd`: rewritten. It may split into `hud.gd` + `ui_theme.gd` + `head_widget.gd` + `menus.gd` if it grows large.
- `game/scripts/game.gd`: front-end state machine, guided sequence, result timing, practice flag, CSV columns, `damage_count`, new arena.
- `game/scripts/haptics_client.gd`: sends `damage_count`; exposes `pulse_active` from telemetry.
- `game/scenes/drone.tscn`, `game/scripts/drone.gd`: quadcopter visual root.
- `game/fonts/`: font files + `OFL.txt`.
- `bridge/main.py`, `bridge/haptics.py`, `bridge/config.json`: damage pulse.
- `tests/game_checks.gd`, `tests/test_haptics.py`, `tests/integration_smoke.gd`: updated and extended.
- Docs: `readme.md` (controls, title screen, practice trial, Shift+5), `phantom_defense_overview.md` (add the damage-buzz decision to "Decisions recorded"), `progress_update.md` (tick items, record FPS).

## 5. Damage buzz: protocol and bridge design

**Snapshot field (game → bridge).** Add `damage_count` to every `threat_snapshot`: a non-negative integer that counts health lost in the current session and resets to 0 on a new session. A counter survives a dropped UDP packet; a one-shot event flag wouldn't. Keep `schema_version` 1. The bridge treats a missing field as 0 and rejects a negative or non-integer value with `ProtocolError`.

**Bridge behaviour (`Bridge`):**

- Track `last_damage_count` per session. The first snapshot of a session only sets the baseline and never triggers a buzz.
- When `damage_count` goes up **and** the bridge is armed **and** the snapshot is active, start a pulse that ends at `now + duration`. Increases while disarmed only update the baseline; don't queue them.
- While a pulse is active, `tick()` sends every motor at `damage_pulse.level` through `calibrate()` (so `channel_min`/`channel_max`/`total_max` still apply) instead of the direction cue. When it ends, the normal target selection resumes.
- Any disarm (S, stale input, protocol error, new session, link reconnect, pause, game over) cancels the pulse at once.
- Telemetry `motor_state` gains `"pulse_active": bool`. The game-side validator ignores unknown keys, but add a type check for it anyway.
- Config: `"damage_pulse": {"enabled": true, "duration_ms": 300, "level": 1.0}`.
  - With the current `total_max` of 2.0, six motors are scaled to about 0.33 each.
  - Leave that scaling in place (it's the power and comfort cap) and note "tune pulse level with the wearer" in the hardware bring-up steps.
- Firmware needs no change: the buzz is ordinary `H,...` frames.

**Tests to add (`tests/test_haptics.py`):**

- an increase while armed gives all-equal levels for about 300 ms, then the direction cue resumes
- an increase while disarmed gives no pulse
- the first snapshot of a session with `damage_count > 0` gives no pulse
- S / stale input / a new session during a pulse gives zero output immediately
- a negative or float `damage_count` is rejected
- a fake serial device receives all-channel frames during the pulse

## 6. Leak checklist (verify in M3 and M4, and again before the demo)

- [ ] No intro card, scenario name, result line or chip names a direction.
- [ ] Hidden drone: no mesh, light, shadow, particle or emissive pixel is visible anywhere on screen.
- [ ] Damage flash is symmetric; there are no directional damage arrows.
- [ ] All audio is non-spatial (existing tones). No new spatial audio.
- [ ] Real trial: widget off, no hit marker or shot effects, CSV `dashboard_visible=false`, `practice=false`.
- [ ] Serial mode in scenarios 1 and 3: the widget starts off.
- [ ] Practice feedback appears only after the response and clears before the next target spawns.

## 7. Checks (run after every milestone)

```bash
python -m unittest discover -s tests -v
C:/Godot/Godot_v4.7.2-stable_win64_console.exe --headless --path game --script ../tests/verify_directions.gd
C:/Godot/Godot_v4.7.2-stable_win64_console.exe --headless --path game --script ../tests/game_checks.gd
# end to end: start `python bridge/main.py --backend simulator` in the background, then
C:/Godot/Godot_v4.7.2-stable_win64_console.exe --headless --path game --script ../tests/integration_smoke.gd
# repeat the end-to-end check with --backend fake
```

Headless checks don't cover the visuals. After M1, M2 and M4, do a rendered run (`C:/Godot/Godot_v4.7.2-stable_win64.exe --path game`), take screenshots where possible, and tell the owner what was and wasn't checked by eye.

## 8. Out of scope for this pass

- A second window or projector-only view.
- A "how it works" screen, live captions or interpretation text on results.
- A buzz on a successful shot (only damage buzzes).
- Spatial audio, direction arrows or radar.
- Any change to the threat selection, interpolation or arming logic beyond the damage pulse.
