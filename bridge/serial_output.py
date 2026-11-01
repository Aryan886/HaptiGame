"""Serial device adapter: complete motor frames in, acknowledgements out.

Link states reported in telemetry: disconnected, ready, stale, error.
An ACK means the firmware accepted a frame, not that a motor vibrated.
"""

from __future__ import annotations

import logging
from typing import Callable, Optional

log = logging.getLogger("bridge.serial")

HELLO_RESEND_S = 0.5


def open_pyserial(port: str, baud: int):
    """Open a real port without toggling DTR/RTS where the driver allows it,
    so an ESP32 is not reset on every connect."""
    try:
        import serial  # imported only at the device boundary
    except ImportError:
        raise OSError("pyserial is not installed; run: python -m pip install -r bridge/requirements.txt") from None

    dev = serial.Serial()
    dev.port = port
    dev.baudrate = baud
    dev.timeout = 0
    dev.write_timeout = 0.1
    dev.dtr = False
    dev.rts = False
    dev.open()
    return dev


class SerialOutput:
    def __init__(self, open_port: Callable[[], object], channels: int, channel_map: list[int],
                 frame_duration_ms: int, backend_name: str = "serial",
                 ready_timeout_s: float = 3.0, ack_timeout_s: float = 0.5, retry_s: float = 2.0):
        if len(channel_map) != channels:
            raise ValueError(f"channel_map has {len(channel_map)} entries for {channels}-channel firmware")
        if not 1 <= frame_duration_ms <= 500:
            raise ValueError("frame_duration_ms must be within 1-500")
        self.backend_name = backend_name
        self._open_port = open_port
        self.channels = channels
        self.channel_map = channel_map
        self.frame_duration_ms = frame_duration_ms
        self.ready_timeout_s = ready_timeout_s
        self.ack_timeout_s = ack_timeout_s
        self.retry_s = retry_s

        self._port = None
        self._buffer = bytearray()
        self._state = "disconnected"   # disconnected | connecting | ready | stale | error
        self._next_retry = 0.0
        self._hello_started = 0.0
        self._hello_last = 0.0
        self._seq = 0
        self._pending: Optional[tuple[int, float]] = None
        self.last_ack_seq: Optional[int] = None
        self.last_error = ""
        # Increments whenever the link (re)becomes ready; the bridge disarms on change.
        self.link_generation = 0

    @property
    def link_state(self) -> str:
        return "disconnected" if self._state == "connecting" else self._state

    @property
    def ready(self) -> bool:
        return self._state == "ready"

    def poll(self, now: float) -> None:
        if self._port is None:
            if now >= self._next_retry:
                self._connect(now)
            return
        try:
            self._read_lines(now)
        except OSError as exc:
            self._fail(now, f"read failed: {exc}", "disconnected")
            return
        if self._state == "connecting":
            if now - self._hello_started > self.ready_timeout_s:
                self._fail(now, "no READY reply to HELLO", "disconnected")
            elif now - self._hello_last >= HELLO_RESEND_S:
                self._send(now, "HELLO")
        elif self._state == "ready" and self._pending and now - self._pending[1] > self.ack_timeout_s:
            self._state = "stale"
            self.last_error = f"no ACK for frame {self._pending[0]} within {self.ack_timeout_s * 1000:.0f} ms"
            log.warning(self.last_error)

    def write_levels(self, levels: list[float], now: float) -> Optional[list[float]]:
        """Send one complete frame in logical order; returns the quantized
        levels (PWM / 255) actually commanded, or None if not sent."""
        if not self.ready:
            return None
        if len(levels) != self.channels:
            raise ValueError(f"{len(levels)} levels for {self.channels}-channel firmware")
        pwm = [max(0, min(255, round(level * 255))) for level in levels]
        physical = [0] * self.channels
        for logical, channel in enumerate(self.channel_map):
            physical[channel] = pwm[logical]
        self._seq += 1
        line = "H,%d,%d,%s" % (self._seq, self.frame_duration_ms, ",".join(str(v) for v in physical))
        if not self._send(now, line):
            return None
        if self._pending is None:
            self._pending = (self._seq, now)
        return [v / 255 for v in pwm]

    def stop(self, now: float) -> None:
        if self._port is not None:
            self._send(now, "STOP")

    def close(self) -> None:
        if self._port is not None:
            try:
                self._port.write(b"STOP\n")
            except OSError:
                pass
            try:
                self._port.close()
            except OSError:
                pass
        self._port = None

    # --- internals ---------------------------------------------------------------
    def _connect(self, now: float) -> None:
        try:
            self._port = self._open_port()
        except Exception as exc:  # pyserial raises SerialException (an OSError subclass) or ImportError
            self._fail(now, f"cannot open port: {exc}", "disconnected")
            return
        self._buffer.clear()
        self._state = "connecting"
        self._hello_started = now
        self._send(now, "HELLO")

    def _send(self, now: float, line: str) -> bool:
        try:
            self._port.write(line.encode("ascii") + b"\n")
        except Exception as exc:
            self._fail(now, f"write failed: {exc}", "disconnected")
            return False
        if line == "HELLO":
            self._hello_last = now
        return True

    def _read_lines(self, now: float) -> None:
        waiting = self._port.in_waiting
        if waiting:
            self._buffer.extend(self._port.read(waiting))
        while b"\n" in self._buffer:
            raw, _, rest = self._buffer.partition(b"\n")
            self._buffer = bytearray(rest)
            self._handle_line(raw.decode("ascii", errors="replace").strip(), now)
        if len(self._buffer) > 1024:
            self._buffer.clear()  # boot noise without newlines

    def _handle_line(self, line: str, now: float) -> None:
        parts = line.split(",")
        if parts[0] == "READY" and self._state == "connecting":
            reported = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else -1
            if reported != self.channels:
                self._fail(now, f"firmware reports {reported} channels; profile expects {self.channels}", "error")
                return
            self._seq = 0
            self._pending = None
            self.last_ack_seq = None
            self._state = "ready"
            self.link_generation += 1
            log.info("serial link ready (%d channels)", self.channels)
        elif parts[0] == "ACK" and len(parts) == 2 and parts[1].isdigit():
            self.last_ack_seq = int(parts[1])
            if self._pending and self.last_ack_seq >= self._pending[0]:
                self._pending = None
            if self._state == "stale":
                self._state = "ready"
                self.link_generation += 1
        elif parts[0] == "ERR":
            self.last_error = f"firmware rejected: {line}"
            log.warning(self.last_error)
        # STOPPED and unrecognised lines (boot messages) are ignored.

    def _fail(self, now: float, message: str, state: str) -> None:
        if message != self.last_error:
            log.warning(message)
        self.last_error = message
        if self._port is not None:
            try:
                self._port.close()
            except Exception:
                pass
        self._port = None
        self._state = state
        self._pending = None
        self._next_retry = now + self.retry_s
