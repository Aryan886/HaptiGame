"""In-process model of firmware/phantom_haptics.ino, exposing the subset of the
pyserial interface that serial_output.py uses. It lets the serial path be
exercised end to end without hardware; it proves nothing about real motors.

Device protocol (newline-terminated ASCII):
  host -> device: HELLO | STOP | H,<seq>,<duration_ms>,<v1>,...,<vN>
  device -> host: READY,<N> | ACK,<seq> | ERR,<seq or ->,<reason> | STOPPED
"""

from __future__ import annotations

import time

COMM_TIMEOUT_MS = 500
MAX_DURATION_MS = 500


class FakeDevice:
    def __init__(self, channels: int = 6, clock=time.monotonic):
        self.channels = channels
        self._clock = clock
        self._rx = bytearray()
        self._tx = bytearray()
        self.session_open = False
        self.last_seq = -1
        self.pwm = [0] * channels
        self._frame_expires = 0.0
        self._last_valid = clock()
        self.is_open = True
        self.log: list[str] = []

    # --- pyserial-like interface -------------------------------------------------
    @property
    def in_waiting(self) -> int:
        return len(self._tx)

    def read(self, size: int = 1) -> bytes:
        out = bytes(self._tx[:size])
        del self._tx[:size]
        return out

    def write(self, data: bytes) -> int:
        if not self.is_open:
            raise OSError("fake device closed")
        self._rx.extend(data)
        while b"\n" in self._rx:
            line, _, rest = self._rx.partition(b"\n")
            self._rx = bytearray(rest)
            self._handle(line.decode("ascii", errors="replace").strip())
        return len(data)

    def close(self) -> None:
        self.is_open = False

    # --- firmware model ----------------------------------------------------------
    def outputs(self) -> list[int]:
        """PWM currently applied, after local expiry and comm timeout."""
        now = self._clock()
        if now >= self._frame_expires or (now - self._last_valid) * 1000 > COMM_TIMEOUT_MS:
            self.pwm = [0] * self.channels
        return list(self.pwm)

    def _reply(self, text: str) -> None:
        self._tx.extend(text.encode("ascii") + b"\n")

    def _handle(self, line: str) -> None:
        self.log.append(line)
        if line == "HELLO":
            self.pwm = [0] * self.channels
            self.session_open = True
            self.last_seq = -1
            self._last_valid = self._clock()
            self._reply(f"READY,{self.channels}")
        elif line == "STOP":
            self.pwm = [0] * self.channels
            self._last_valid = self._clock()
            self._reply("STOPPED")
        elif line.startswith("H,"):
            self._handle_frame(line.split(","))
        else:
            self._reply("ERR,-,unknown_command")

    def _handle_frame(self, parts: list[str]) -> None:
        try:
            seq = int(parts[1])
        except (IndexError, ValueError):
            self._reply("ERR,-,bad_seq")
            return
        if not self.session_open:
            self._reply(f"ERR,{seq},no_hello")
            return
        if len(parts) != 3 + self.channels:
            self._reply(f"ERR,{seq},channel_count")
            return
        try:
            duration = int(parts[2])
            values = [int(v) for v in parts[3:]]
        except ValueError:
            self._reply(f"ERR,{seq},bad_number")
            return
        if seq <= self.last_seq:
            self._reply(f"ERR,{seq},stale_seq")
            return
        if not 1 <= duration <= MAX_DURATION_MS or any(not 0 <= v <= 255 for v in values):
            self._reply(f"ERR,{seq},out_of_range")
            return
        now = self._clock()
        self.last_seq = seq
        self.pwm = values
        self._frame_expires = now + duration / 1000.0
        self._last_valid = now
        self._reply(f"ACK,{seq}")
