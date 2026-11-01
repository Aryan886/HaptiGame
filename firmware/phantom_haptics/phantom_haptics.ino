// Phantom Defense reference firmware for ESP32 (Arduino core 2.x or 3.x).
// UNVERIFIED: written before any hardware existed. Bench-test every behavior
// below before wearing the device. Motors must be driven through transistors
// or a motor driver, never directly from GPIO pins.
//
// Protocol (newline-terminated ASCII, 115200 baud), mirrored by bridge/fake_device.py:
//   host -> device: HELLO | STOP | H,<seq>,<duration_ms>,<v1>,...,<vN>
//   device -> host: READY,<N> | ACK,<seq> | ERR,<seq or ->,<reason> | STOPPED
// Safety: outputs start off; a frame expires after duration_ms; all outputs
// clear when no valid command arrives for COMM_TIMEOUT_MS; invalid or
// duplicate commands never extend output time.

#include <Arduino.h>

// Logical channel order is set by bridge/config.json channel_map; this table
// only says which GPIO drives physical channel M1..MN.
static const uint8_t MOTOR_PINS[] = {25, 26, 27, 32, 33, 14};
static const int CHANNELS = sizeof(MOTOR_PINS) / sizeof(MOTOR_PINS[0]);

static const uint32_t COMM_TIMEOUT_MS = 500;
static const uint32_t MAX_DURATION_MS = 500;
static const size_t LINE_MAX = 128;

static char line_buf[LINE_MAX];
static size_t line_len = 0;
static bool line_overflow = false;

static bool session_open = false;
static long last_seq = -1;
static uint32_t frame_expires_ms = 0;
static uint32_t last_valid_ms = 0;
static bool outputs_on = false;

static void write_all(const uint8_t* values) {
  bool any = false;
  for (int i = 0; i < CHANNELS; i++) {
    analogWrite(MOTOR_PINS[i], values[i]);
    any = any || values[i] > 0;
  }
  outputs_on = any;
}

static void all_off() {
  static const uint8_t zeros[CHANNELS] = {0};
  write_all(zeros);
}

static bool parse_uint(const char* s, long max_value, long* out) {
  if (*s == '\0') return false;
  long v = 0;
  for (; *s; s++) {
    if (*s < '0' || *s > '9') return false;
    v = v * 10 + (*s - '0');
    if (v > max_value) return false;
  }
  *out = v;
  return true;
}

static void handle_frame(char* fields) {
  // fields points just past "H,"
  char* tokens[3 + 16];
  int count = 0;
  for (char* tok = strtok(fields, ","); tok && count < (int)(sizeof(tokens) / sizeof(tokens[0])); tok = strtok(nullptr, ",")) {
    tokens[count++] = tok;
  }
  long seq;
  if (count < 1 || !parse_uint(tokens[0], 2147483647L, &seq)) {
    Serial.println("ERR,-,bad_seq");
    return;
  }
  if (!session_open) { Serial.printf("ERR,%ld,no_hello\n", seq); return; }
  if (count != 2 + CHANNELS) { Serial.printf("ERR,%ld,channel_count\n", seq); return; }
  long duration;
  uint8_t values[CHANNELS];
  if (!parse_uint(tokens[1], 100000, &duration)) { Serial.printf("ERR,%ld,bad_number\n", seq); return; }
  for (int i = 0; i < CHANNELS; i++) {
    long v;
    if (!parse_uint(tokens[2 + i], 100000, &v)) { Serial.printf("ERR,%ld,bad_number\n", seq); return; }
    if (v > 255) { Serial.printf("ERR,%ld,out_of_range\n", seq); return; }
    values[i] = (uint8_t)v;
  }
  if (seq <= last_seq) { Serial.printf("ERR,%ld,stale_seq\n", seq); return; }
  if (duration < 1 || duration > (long)MAX_DURATION_MS) { Serial.printf("ERR,%ld,out_of_range\n", seq); return; }

  uint32_t now = millis();
  last_seq = seq;
  frame_expires_ms = now + (uint32_t)duration;
  last_valid_ms = now;
  write_all(values);
  Serial.printf("ACK,%ld\n", seq);
}

static void handle_line(char* line) {
  if (strcmp(line, "HELLO") == 0) {
    all_off();
    session_open = true;
    last_seq = -1;
    last_valid_ms = millis();
    Serial.printf("READY,%d\n", CHANNELS);
  } else if (strcmp(line, "STOP") == 0) {
    all_off();
    last_valid_ms = millis();
    Serial.println("STOPPED");
  } else if (line[0] == 'H' && line[1] == ',') {
    handle_frame(line + 2);
  } else {
    Serial.println("ERR,-,unknown_command");
  }
}

void setup() {
  for (int i = 0; i < CHANNELS; i++) {
    pinMode(MOTOR_PINS[i], OUTPUT);
    digitalWrite(MOTOR_PINS[i], LOW);
  }
  all_off();
  Serial.begin(115200);
}

void loop() {
  while (Serial.available() > 0) {
    char c = (char)Serial.read();
    if (c == '\r') continue;
    if (c == '\n') {
      line_buf[line_len] = '\0';
      if (line_overflow) Serial.println("ERR,-,line_too_long");
      else if (line_len > 0) handle_line(line_buf);
      line_len = 0;
      line_overflow = false;
    } else if (line_len < LINE_MAX - 1) {
      line_buf[line_len++] = c;
    } else {
      line_overflow = true;
    }
  }

  if (outputs_on) {
    uint32_t now = millis();
    // Unsigned subtraction handles millis() wraparound.
    bool expired = (int32_t)(now - frame_expires_ms) >= 0;
    bool silent = now - last_valid_ms > COMM_TIMEOUT_MS;
    if (expired || silent) all_off();
  }
}
