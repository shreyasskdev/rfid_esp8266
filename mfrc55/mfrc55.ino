// ESP8266 (NodeMCU) RFID Attendance - WiFi/WebSocket version
//
// Wiring (NodeMCU -> RC522):
//   D8 (GPIO15) -> SDA/SS
//   D5 (GPIO14) -> SCK
//   D7 (GPIO13) -> MOSI
//   D6 (GPIO12) -> MISO
//   D2 (GPIO4)  -> RST
//   3V3         -> 3.3V
//   GND         -> GND
// Buzzer: between D1 (GPIO5) and GND
//
// Libraries needed (Library Manager):
//   - MFRC522v2 (by GithubCommunity)
//   - WebSockets (by Markus Sattler / Links2004)
//
// The ESP8266 creates its own WiFi hotspot. On your phone:
//   1. Connect to the hotspot (AP_SSID / AP_PASS below)
//   2. App connects to:  ws://192.168.4.1:81
// The text protocol is identical to the old BLE one.

#include <ESP8266WiFi.h>
#include <WebSocketsServer.h>
#include <MFRC522v2.h>
#include <MFRC522DriverSPI.h>
#include <MFRC522DriverPinSimple.h>
#include <LittleFS.h>
#include <time.h>
#include <sys/time.h>

// ---------- CONFIG ----------
const char* AP_SSID = "ESP_Attendance";    // hotspot name
const char* AP_PASS = "attend1234";        // min 8 characters (use "" for an open network)
const int   AP_CHANNEL = 6;
const int   AP_MAX_CLIENTS = 4;
const char* TZ_INFO = "IST-5:30";          // timezone (India)
// -----------------------------

#define LED_PIN          LED_BUILTIN       // GPIO2 (D4), active LOW on NodeMCU
#define BUZZER_PIN       5                 // D1 (GPIO5) - supports tone()
#define BOOT_BUTTON_PIN  0                 // FLASH button (D3)
#define RST_PIN          4                 // D2
#define SS_PIN_NUM       15                // D8

#define LED_ON()  digitalWrite(LED_PIN, LOW)
#define LED_OFF() digitalWrite(LED_PIN, HIGH)

MFRC522DriverPinSimple ss_pin(SS_PIN_NUM);
MFRC522DriverSPI driver{ss_pin};
MFRC522 mfrc522{driver};

WebSocketsServer webSocket(81);

int clientCount = 0;
bool deviceConnected = false;
bool isAttendanceOpen = true;
bool isPreparingToRegister = false;

// ---------- Helpers ----------
// Wait while still servicing WiFi/WebSocket
void waitMs(unsigned long ms) {
  unsigned long end = millis() + ms;
  while (millis() < end) {
    webSocket.loop();
    yield();
  }
}

void notifyAll(const String& s) {
  if (deviceConnected) {
    String copy = s;
    webSocket.broadcastTXT(copy);
  }
}

// ---------- Sound engine ----------
void play(int f, int t) { tone(BUZZER_PIN, f); delay(t); noTone(BUZZER_PIN); }

void sndStartup()  { play(400, 100); play(800, 100); play(1200, 200); }
void sndSuccess()  { play(1500, 80); delay(30); play(2000, 150); }
void sndError()    { play(150, 300); delay(50); play(150, 400); }
void sndRegister() { play(1800, 50); delay(30); play(1800, 50); delay(30); play(1800, 50); }
void sndInfo()     { play(1000, 200); }
void sndAction()   { play(1200, 80); }

// ---------- Time ----------
String getTodayDate() {
  time_t now = time(nullptr);
  if (now < 1700000000) return "00-00-2024";   // time not synced yet
  struct tm timeinfo;
  localtime_r(&now, &timeinfo);
  char buf[15];
  strftime(buf, sizeof(buf), "%d-%m-%Y", &timeinfo);
  return String(buf);
}

// ---------- Persistent state (replaces Preferences) ----------
void saveOpenState(bool open) {
  File f = LittleFS.open("/state.txt", "w");
  if (f) { f.print(open ? "1" : "0"); f.close(); }
}

bool loadOpenState() {
  if (!LittleFS.exists("/state.txt")) return true;
  File f = LittleFS.open("/state.txt", "r");
  if (!f) return true;
  char c = f.read();
  f.close();
  return c != '0';
}

// ---------- Storage ----------
bool isStudentRegistered(String uid) {
  if (!LittleFS.exists("/students.csv")) return false;
  File f = LittleFS.open("/students.csv", "r");
  if (!f) return false;
  while (f.available()) {
    if (f.readStringUntil('\n').startsWith(uid + ",")) { f.close(); return true; }
  }
  f.close();
  return false;
}

void logAttendance(String uid) {
  String path = "/" + getTodayDate() + ".txt";
  if (LittleFS.exists(path)) {
    File check = LittleFS.open(path, "r");
    if (check) {
      while (check.available()) {
        if (check.readStringUntil('\n').indexOf(uid) != -1) { check.close(); return; }
      }
      check.close();
    }
  }
  File f = LittleFS.open(path, "a");
  if (f) { f.println(uid); f.close(); }
}

// The WebSockets library wants a non-const String&, so pass a named variable
void sendTo(uint8_t num, String s) { webSocket.sendTXT(num, s); }

void sendFile(uint8_t num, String path, String prefix) {
  if (!LittleFS.exists(path)) {
    sendTo(num, prefix + "END");
    return;
  }
  File file = LittleFS.open(path, "r");
  if (!file) { sendTo(num, prefix + "END"); return; }
  while (file.available()) {
    String line = file.readStringUntil('\n');
    line.trim();
    if (line.length() > 3) {
      sendTo(num, prefix + line);
      delay(10);   // gentle pacing
      yield();
    }
  }
  file.close();
  sendTo(num, prefix + "END");
}

// ---------- Command handler (same protocol as BLE version) ----------
void handleCommand(uint8_t num, String rx) {
  rx.trim();
  if (rx == "START_ATT") {
    isAttendanceOpen = true; saveOpenState(true);
    LittleFS.remove("/" + getTodayDate() + ".txt");
    sndSuccess();
  }
  else if (rx == "RESUME_ATT") { isAttendanceOpen = true;  saveOpenState(true);  sndSuccess(); }
  else if (rx == "STOP_ATT")   { isAttendanceOpen = false; saveOpenState(false); sndAction(); }
  else if (rx == "PREP_REG")   { isPreparingToRegister = true; sndAction(); }
  else if (rx.startsWith("ADD:")) {
    String entry = rx.substring(4);
    int comma = entry.indexOf(',');
    String newUid = comma > 0 ? entry.substring(0, comma) : entry;
    if (isStudentRegistered(newUid)) {
      // This card is already assigned to someone - refuse
      sndError();
      sendTo(num, "ERR:DUP:" + newUid);
    } else {
      File f = LittleFS.open("/students.csv", "a");
      if (f) { f.println(entry); f.close(); }
      sndSuccess();
    }
  }
  else if (rx.startsWith("DEL:")) {
    String target = rx.substring(4);
    String content = "";
    if (LittleFS.exists("/students.csv")) {
      File f = LittleFS.open("/students.csv", "r");
      while (f.available()) {
        String l = f.readStringUntil('\n');
        l.trim();
        if (l.indexOf(target) == -1 && l.length() > 5) content += l + "\n";
      }
      f.close();
    }
    File f = LittleFS.open("/students.csv", "w");
    if (f) { f.print(content); f.close(); }
    sndAction();
  }
  else if (rx == "GET_STUDENTS") sendFile(num, "/students.csv", "STU:");
  else if (rx == "GET_TODAY")    sendFile(num, "/" + getTodayDate() + ".txt", "TOD:");
  else if (rx == "GET_STATUS")   webSocket.sendTXT(num, isAttendanceOpen ? "STAT:OPEN" : "STAT:CLOSED");
  else if (rx.startsWith("GET_HIST:")) sendFile(num, "/" + rx.substring(9) + ".txt", "HIS:");
  else if (rx.startsWith("TIME:")) {
    struct timeval tv;
    tv.tv_sec = rx.substring(5).toInt();
    tv.tv_usec = 0;
    settimeofday(&tv, NULL);
  }
}

void onWsEvent(uint8_t num, WStype_t type, uint8_t* payload, size_t length) {
  switch (type) {
    case WStype_CONNECTED:
      clientCount++;
      deviceConnected = true;
      break;
    case WStype_DISCONNECTED:
      if (clientCount > 0) clientCount--;
      deviceConnected = clientCount > 0;
      if (!deviceConnected) isPreparingToRegister = false;
      break;
    case WStype_TEXT:
      handleCommand(num, String((char*)payload));
      break;
    default:
      break;
  }
}

// ---------- Setup ----------
void startHotspot() {
  WiFi.mode(WIFI_AP);
  IPAddress ip(192, 168, 4, 1), gw(192, 168, 4, 1), mask(255, 255, 255, 0);
  WiFi.softAPConfig(ip, gw, mask);
  bool ok;
  if (strlen(AP_PASS) >= 8) ok = WiFi.softAP(AP_SSID, AP_PASS, AP_CHANNEL, false, AP_MAX_CLIENTS);
  else                      ok = WiFi.softAP(AP_SSID, nullptr, AP_CHANNEL, false, AP_MAX_CLIENTS);
  Serial.println(ok ? "Hotspot started" : "Hotspot FAILED");
  Serial.print("SSID: "); Serial.println(AP_SSID);
  Serial.print("IP:   "); Serial.println(WiFi.softAPIP());
}

void setup() {
  Serial.begin(115200);
  pinMode(LED_PIN, OUTPUT); LED_OFF();
  pinMode(BUZZER_PIN, OUTPUT); digitalWrite(BUZZER_PIN, LOW);
  pinMode(BOOT_BUTTON_PIN, INPUT_PULLUP);

  LittleFS.begin();
  isAttendanceOpen = loadOpenState();

  startHotspot();
  setenv("TZ", TZ_INFO, 1);   // no internet in hotspot mode: app sends the time via "TIME:<epoch>"
  tzset();

  webSocket.begin();
  webSocket.onEvent(onWsEvent);
  webSocket.enableHeartbeat(15000, 3000, 2);   // drop phones that vanish without closing

  // RC522 hardware reset (MFRC522v2 doesn't toggle RST itself)
  pinMode(RST_PIN, OUTPUT);
  digitalWrite(RST_PIN, LOW);  delay(10);
  digitalWrite(RST_PIN, HIGH); delay(50);
  mfrc522.PCD_Init();

  sndStartup();
}

// ---------- Loop ----------
void loop() {
  webSocket.loop();

  // FLASH button: kick connected app clients
  if (digitalRead(BOOT_BUTTON_PIN) == LOW) {
    delay(50);
    if (digitalRead(BOOT_BUTTON_PIN) == LOW) {
      sndAction();
      webSocket.disconnect();   // disconnect all clients
      while (digitalRead(BOOT_BUTTON_PIN) == LOW) delay(10);
    }
  }

  if (!mfrc522.PICC_IsNewCardPresent() || !mfrc522.PICC_ReadCardSerial()) return;

  String uid = "";
  for (byte i = 0; i < mfrc522.uid.size; i++) {
    if (mfrc522.uid.uidByte[i] < 0x10) uid += "0";
    uid += String(mfrc522.uid.uidByte[i], HEX);
  }

  bool registered = isStudentRegistered(uid);

  // 1. App is explicitly waiting to register a card
  if (isPreparingToRegister) {
    if (registered) {
      // Card already belongs to a student: reject, keep waiting for another card
      sndError();
      notifyAll("DUP:" + uid);
      waitMs(1000);
    } else {
      sndRegister();
      notifyAll("NEW_UID:" + uid);
      isPreparingToRegister = false;
      waitMs(2000);
    }
  }
  // 2. Attendance is running
  else if (isAttendanceOpen) {
    if (registered) {
      LED_ON(); sndSuccess(); logAttendance(uid);
      notifyAll("LIVE:" + uid);
      waitMs(1500); LED_OFF();
    } else {
      sndError();
      notifyAll("NEW_UID:" + uid);
      waitMs(1000);
    }
  }
  // 3. Standby (session stopped)
  else {
    if (registered) {
      sndInfo();
      notifyAll("INFO:" + uid);
    } else {
      sndRegister();
      notifyAll("NEW_UID:" + uid);
    }
    waitMs(1000);
  }

  mfrc522.PICC_HaltA();
  mfrc522.PCD_StopCrypto1();
}
