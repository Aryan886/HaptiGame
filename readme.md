# Phantom Defense: 360° haptics demo

You stay at the centre of an arena. A vibration tells you where a drone is, and you turn to find it and shoot. The full specification and its recorded decisions are in [phantom_defense_overview.md](phantom_defense_overview.md).

**Status:** the game, the simulator bridge and the serial path are tested in software. **No hardware exists yet.** The serial path has only been run against `bridge/fake_device.py`, and `firmware/` has not been compiled or run on a board.

Haptic cues come from the positions of drones the game already knows about. **The project does not detect or localize sound.**

## Requirements

- Windows, with Godot **4.7.2-stable** at `C:\Godot\` (set `GODOT` to use another path).
- Python 3.12. The simulator uses only the standard library.
- Serial hardware needs pyserial: `python -m pip install -r bridge/requirements.txt`.

## Run

```bat
run_demo.bat              :: simulator bridge, then the game
run_demo.bat fake         :: serial code path against an in-process fake device
run_demo.bat serial --port COM5
run_demo.bat simulator --profile eight
```

To start the two parts by hand, run `python bridge/main.py --backend simulator` first, then open `game/` in Godot or run `C:\Godot\Godot_v4.7.2-stable_win64.exe --path game`. The game also runs without the bridge; the HUD then shows **bridge unavailable**.

The game opens on a **title screen**. **Start guided demo** runs scenarios 1 → 2 → 3 → 4, each with an intro card (what to do, what to feel), play, then a results screen with **Next**. The scenario list starts any scenario with its intro card; keys 1–5 start one directly from anywhere.

Haptics are **off at startup**. Press **E** to enable them. An amber **HAPTICS OFF · PRESS E** strip stays on screen until you do.

## Controls

| Key | Action |
|---|---|
| Mouse / left click | Turn and look / shoot (in the trial: submit a direction) |
| 1 | Hidden target (stationary) |
| 2 | Orbiting target |
| 3 | Approaching target (hidden) |
| 4 | 60 s survival round |
| 5 | Direction trial (24 targets, invisible, logged) |
| E / S | Enable haptics / stop haptics immediately |
| M | Switch between nearest-motor and interpolated-motor output |
| H | Toggle hidden mode and restart the scenario |
| F1 | Show or hide the motor dashboard (hidden automatically during the trial) |
| Esc | Pause menu (Resume, Restart, Controls, Title) or resume |
| R | Restart with a new session (haptics turn off) |

Trial results are saved as CSV files in `%APPDATA%\Godot\app_userdata\Phantom Defense\trials\`. The results screen shows the exact path when a trial ends.

## Recovery

- **Output stopped and won't come back:** press **S**, then **E**. The bridge stays disarmed after startup, a new session, a stale or invalid input, a link reconnect, or loss of window focus, until it sees haptics go from disabled to enabled again.
- **"bridge unavailable":** the bridge isn't running, or hasn't sent telemetry in the last 250 ms. Check the bridge console window.
- **"telemetry socket error":** another game instance is already using UDP port 9001.
- **Bridge prints "cannot bind":** another bridge is already using UDP port 9000.

## Checks

```bash
python -m unittest discover -s tests -v                                   # bridge: fixtures, validation, watchdog, serial/fake device
C:/Godot/Godot_v4.7.2-stable_win64_console.exe --headless --path game --script ../tests/verify_directions.gd
C:/Godot/Godot_v4.7.2-stable_win64_console.exe --headless --path game --script ../tests/game_checks.gd
python bridge/main.py &   # then:
C:/Godot/Godot_v4.7.2-stable_win64_console.exe --headless --path game --script ../tests/integration_smoke.gd
```

Both `bridge/` and the game check themselves against the same fixtures in `tests/direction_cases.json`. Headless checks don't replace testing the rendered game by hand or testing on hardware.

## Bringing up hardware

1. Wire the motors through transistors or a motor driver, never directly from GPIO pins, and fit a physical power cut-off. Set `MOTOR_PINS` in `firmware/phantom_haptics/phantom_haptics.ino` and flash it with the ESP32 Arduino core.
2. Open a serial monitor at 115200 baud. Check that `HELLO` returns `READY,6`. Check that `H,1,150,0,120,0,0,0,0` runs M2 for about 150 ms and returns `ACK,1`. Check that `STOP` returns `STOPPED`, and that output stops when no command arrives for 500 ms.
3. Set `serial.port` in `bridge/config.json` (or pass `--port`). Trigger each channel on its own, record its physical position, then fix `channel_map`.
4. Set `channel_min` (startup threshold) and `channel_max` (comfortable cap) for each channel, plus `total_max`, with the wearer.
5. Run `run_demo.bat serial`. The dashboard should show `serial ready` and an advancing ACK sequence. An ACK means the firmware accepted a frame; it doesn't prove that a motor vibrated.

## Known limitations

- None of the hardware behaviour is verified: firmware timing, PWM frequency and how the motors feel.
- No export yet, because the Godot export templates aren't installed. `game/export_presets.cfg` is ready; install the templates for 4.7.2, then export to `game/export/phantom_defense.exe`. `run_demo.bat` uses the export once it exists.
- The haptic reference is camera yaw, not your physical head orientation.
- Interpolated output blends the commanded levels of two motors. Whether wearers feel a position between the motors has to be measured with the trial.
