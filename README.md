# RFID Attendance System (ESP8266 + Flutter)

A standalone RFID attendance system. An **ESP8266 (NodeMCU)** with an **RC522 RFID reader** and a buzzer creates its **own WiFi hotspot**. A **Flutter mobile app** connects to it over WebSocket to manage students, control attendance sessions, watch scans live and browse past records. No internet or router is needed.

```
 RFID card ──► RC522 ──► ESP8266 (hotspot + WebSocket server, LittleFS storage)
                                  ▲
                                  │ ws://192.168.4.1:81
                                  ▼
                         Flutter app on your phone
```

## Features

- Live attendance board with PRESENT / ABSENT status per student
- Start, stop, resume or restart (fresh start) an attendance session
- Register students by tapping their card from the app
- Duplicate-card protection: one card cannot be assigned to two students
- Attendance history by date
- Distinct buzzer sounds for success, error, registration and info
- Data stored on the ESP8266's flash (survives power cycles)
- Works fully offline over the device's own hotspot

## Repository layout

| Part | What it is |
|---|---|
| `attendance_esp8266/attendance_esp8266.ino` | ESP8266 firmware (Arduino). The sketch must sit in a folder with the same name. |
| `rfid_attendance_esp_mobile/` | Flutter app (`lib/main.dart`, `pubspec.yaml`, ...) |
| `README.md` | This file |

## Hardware

| Part | Notes |
|---|---|
| NodeMCU ESP8266 (ESP-12E) | Any NodeMCU-style board |
| MFRC522 / RC522 RFID reader | 3.3V module |
| RFID cards or tags | 13.56 MHz (MIFARE) |
| Buzzer | Passive buzzer module (e.g. KY-006) gives different tones; an active buzzer also works but beeps at a fixed pitch |
| Jumper wires, breadboard, USB cable | |

### Wiring

| RC522 pin | NodeMCU pin | GPIO |
|---|---|---|
| SDA / SS | D8 | 15 |
| SCK | D5 | 14 |
| MOSI | D7 | 13 |
| MISO | D6 | 12 |
| RST | D2 | 4 |
| 3.3V | 3V3 | - |
| GND | GND | - |
| IRQ | not connected | - |

| Buzzer pin | NodeMCU pin |
|---|---|
| S (signal) | D1 (GPIO5) |
| - (ground) | GND |
| middle pin (3-pin KY-006) | leave unconnected |

Notes:
- Power the RC522 from **3.3V only**, never 5V.
- On a 3-pin KY-006 module the **"-" pin must be connected**; it is the ground leg.
- The D0 pin does not support `tone()` on the ESP8266, which is why the buzzer is on D1.
- The onboard LED (D4) and the FLASH button (D3 / GPIO0) are used by the firmware. Do not wire anything else to them.

## Firmware setup (ESP8266)

### 1. Arduino IDE

1. Install **Arduino IDE 2**.
2. Add the ESP8266 board package: in **File > Preferences**, add this URL under "Additional boards manager URLs":
   `http://arduino.esp8266.com/stable/package_esp8266com_index.json`
3. In **Boards Manager**, install **"esp8266" by ESP8266 Community**.

### 2. Libraries (Library Manager)

| Library | Author |
|---|---|
| **MFRC522v2** | GithubCommunity |
| **WebSockets** | Markus Sattler (Links2004) |

Similar names such as "ArduinoWebsockets" or the old "MFRC522" do not work. `LittleFS`, `ESP8266WiFi` and `time.h` come with the board package.

### 3. Board settings

- **Board:** NodeMCU 1.0 (ESP-12E Module)
- **Flash Size:** 4MB (FS:2MB OTA:~1MB). A filesystem partition is required, so do not choose "no FS".
- **Upload Speed:** 115200

### 4. Configure and flash

Edit the config block at the top of the sketch if you want:

```cpp
const char* AP_SSID = "ESP_Attendance";   // hotspot name
const char* AP_PASS = "attend1234";       // min 8 characters
const int   AP_CHANNEL = 6;
const int   AP_MAX_CLIENTS = 4;
const char* TZ_INFO = "IST-5:30";         // timezone
```

Upload the sketch. Open the Serial Monitor at 115200 baud. You should see the hotspot SSID and IP (`192.168.4.1`) and hear the startup chirp (three rising tones).

## Mobile app setup (Flutter)

### Requirements

- Flutter SDK (the app uses Cupertino widgets and runs on Android and iOS)
- A phone or emulator

### Dependencies

In `pubspec.yaml`, these packages are used:

```yaml
dependencies:
  flutter:
    sdk: flutter
  cupertino_icons:
  intl:
  web_socket_channel: ^3.0.0
```

Quick way to get there:

```
flutter pub add web_socket_channel intl
flutter pub get
```

(Remove `flutter_blue_plus` if it is still listed; Bluetooth is no longer used.)

### Platform permissions

- **Android:** `android/app/src/main/AndroidManifest.xml` needs
  `<uses-permission android:name="android.permission.INTERNET"/>` (required in release builds).
- **iOS 14+:** add `NSLocalNetworkUsageDescription` to `Info.plist` with a short reason, for example "Connect to the attendance scanner". The system asks for local-network permission on first connect.

### Run

```
cd rfid_attendance_esp_mobile
flutter run
```

The scanner address is set at the top of `lib/main.dart`:

```dart
const String kDeviceHost = '192.168.4.1';
const int kDevicePort = 81;
```

## How to use

1. Power the ESP8266. Wait for the startup chirp.
2. On your phone, join the WiFi network **ESP_Attendance** (password `attend1234` unless you changed it).
   - Android may warn "no internet". Choose to stay connected.
   - If the app cannot connect, **turn off mobile data**. Android may otherwise route traffic over mobile data.
3. Open the app and tap **Connect Scanner**. The app syncs the clock, status, students and today's attendance.
4. **Directory tab > Add Student:** enter name and roll number, tap **Scan Card**, tap the card on the reader, then **Finalize Registration**.
5. **Live tab:** attendance is recording by default. Students tap their cards and show as PRESENT. Use **Stop**, then **Continue** (keep today's records) or **Fresh Start** (clear today's records and start again).
6. **History tab:** pick a date to see who was present.

### Buzzer sounds

| Sound | Meaning |
|---|---|
| Three rising tones | Startup |
| Short rising ding-ding | Attendance recorded / command accepted |
| Low double buzz | Unknown card during attendance, or duplicate card |
| Fast triple chirp | New card detected / registration scan |
| Single neutral beep | Known card while attendance is stopped |
| Short click beep | Control action (stop, prepare registration, delete, button press) |

The **FLASH** button on the NodeMCU disconnects all connected app clients.

## How it works

### Storage (LittleFS on the ESP8266)

| File | Content |
|---|---|
| `/students.csv` | One line per student: `uid,name,roll` |
| `/DD-MM-YYYY.txt` | UIDs that marked attendance on that day |
| `/state.txt` | Whether attendance is open (`1`) or stopped (`0`) |

### Time

The hotspot has no internet, so the app sends the phone's time (`TIME:<epoch>`) on every connect. The ESP8266 clock resets on reboot. Until the app connects, attendance files are saved under `00-00-2024.txt`. Connect the app after every power-up.

### WebSocket protocol (port 81, text frames)

Commands from the app:

| Command | Action |
|---|---|
| `TIME:<epoch seconds>` | Set the device clock |
| `START_ATT` | Fresh start: clear today's file, open attendance |
| `RESUME_ATT` | Open attendance, keep today's records |
| `STOP_ATT` | Stop attendance |
| `PREP_REG` | Wait for a card to register (auto-expires after 30 s) |
| `CANCEL_REG` | Leave registration mode |
| `ADD:<uid>,<name>,<roll>` | Add a student (rejected if the card is taken) |
| `DEL:<uid>` | Remove a student |
| `GET_STATUS` / `GET_STUDENTS` / `GET_TODAY` | Request status, student list, today's UIDs |
| `GET_HIST:<DD-MM-YYYY>` | Request a past day's UIDs |

Messages from the scanner:

| Message | Meaning |
|---|---|
| `STAT:OPEN` / `STAT:CLOSED` | Attendance state |
| `STU:<uid,name,roll>` ... `STU:END` | Student list |
| `TOD:<uid>` ... `TOD:END` | Today's attendance |
| `HIS:<uid>` ... `HIS:END` | Historical attendance |
| `LIVE:<uid>` | A registered card was just scanned during attendance |
| `INFO:<uid>` | A registered card was scanned while stopped |
| `NEW_UID:<uid>` | An unregistered card was scanned |
| `DUP:<uid>` | A registered card was scanned during registration |
| `ERR:DUP:<uid>` | `ADD` refused because the card is already registered |

## Troubleshooting

| Problem | Fix |
|---|---|
| `WebSocketsServer.h` or `MFRC522v2.h` not found | Install the libraries listed above |
| `cannot bind non-const lvalue reference` | Use the latest sketch (it sends through the `sendTo()` helper) |
| `Couldn't resolve package web_socket_channel` | Run `flutter pub add web_socket_channel` |
| App cannot connect | Join the ESP_Attendance WiFi first, turn off mobile data, check the IP is `192.168.4.1` |
| Reader never detects cards | Check wiring (3.3V, SS on D8, RST on D2) and that the RC522 has 3.3V power |
| Buzzer silent | Check that both S and "-" are wired; read the pin labels on the module; try the test sketch below |
| Attendance saved under `00-00-2024.txt` | The app has not synced the time yet. Connect the app, then use **Fresh Start** or re-sync |
| Students vanish after re-flashing | Flash size set without a filesystem, or "erase all flash" was used. Use a 2MB FS option and avoid full erase |

Buzzer test sketch:

```cpp
void setup() { pinMode(5, OUTPUT); }
void loop() { tone(5, 2000); delay(500); noTone(5); delay(500); }
```

## Notes and limitations

- Up to 4 phones can connect to the hotspot at once.
- The hotspot password is sent over the air as standard WPA2; the WebSocket itself is unencrypted. This is fine for a local classroom setup but not for sensitive data.
- Changing the timezone requires editing `TZ_INFO` in the firmware.
- Students are identified by card UID. Anyone can clone a MIFARE UID, so this is attendance convenience, not security.