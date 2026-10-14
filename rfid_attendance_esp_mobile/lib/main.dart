import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

// --- Scanner connection settings (ESP8266 hotspot) -----------------------------------
// Phone must be connected to the ESP8266 WiFi hotspot (ESP_Attendance).
const String kDeviceHost = '192.168.4.1';
const int kDevicePort = 81;

// --- Global Theme & Signal Management ---
ValueNotifier<String?> scanSignal = ValueNotifier(null);
ValueNotifier<String?> dupSignal = ValueNotifier(null); // name of existing owner
ValueNotifier<ThemeMode> themeNotifier = ValueNotifier(ThemeMode.system);

enum ThemeMode { system, light, dark }

void main() => runApp(const ZincApp());

// --- Consistent Spacing & Typography -------------------------------------------------
class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double button = 14;
  static const EdgeInsets screenHorizontal = EdgeInsets.symmetric(
    horizontal: lg,
  );
  static const EdgeInsets screenVertical = EdgeInsets.symmetric(vertical: lg);
}

class AppTextStyles {
  static TextStyle headline(BuildContext context) => TextStyle(
    fontSize: 20,
    fontWeight: FontWeight.bold,
    color: ZincColors.text(context),
  );
  static TextStyle title(BuildContext context) => TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w600,
    color: ZincColors.text(context),
  );
  static TextStyle body(BuildContext context) => TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.normal,
    color: ZincColors.text(context),
  );
  static TextStyle caption(BuildContext context) => TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w400,
    color: ZincColors.mutedText(context),
  );
  static TextStyle badge(BuildContext context) => TextStyle(
    fontSize: 9,
    fontWeight: FontWeight.w900,
    color: ZincColors.text(context),
  );
}

class ZincColors {
  static const zinc50 = Color(0xFFFAFAFA);
  static const zinc100 = Color(0xFFF4F4F5);
  static const zinc200 = Color(0xFFE4E4E7);
  static const zinc300 = Color(0xFFD4D4D8);
  static const zinc400 = Color(0xFFA1A1AA);
  static const zinc500 = Color(0xFF71717A);
  static const zinc800 = Color(0xFF27272A);
  static const zinc900 = Color(0xFF18181B);
  static const zinc950 = Color(0xFF09090B);

  static Brightness getBrightness(BuildContext context) {
    if (themeNotifier.value == ThemeMode.light) return Brightness.light;
    if (themeNotifier.value == ThemeMode.dark) return Brightness.dark;
    return MediaQuery.platformBrightnessOf(context);
  }

  static Color background(BuildContext context) =>
      getBrightness(context) == Brightness.dark ? zinc950 : zinc50;
  static Color surface(BuildContext context) =>
      getBrightness(context) == Brightness.dark ? zinc900 : zinc50;
  static Color border(BuildContext context) =>
      getBrightness(context) == Brightness.dark ? zinc800 : zinc200;
  static Color text(BuildContext context) =>
      getBrightness(context) == Brightness.dark ? zinc50 : zinc950;
  static Color mutedText(BuildContext context) =>
      getBrightness(context) == Brightness.dark ? zinc400 : zinc500;
}

class ZincApp extends StatelessWidget {
  const ZincApp({super.key});
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeNotifier,
      builder: (context, currentMode, child) {
        return CupertinoApp(
          theme: CupertinoThemeData(
            brightness: currentMode == ThemeMode.light
                ? Brightness.light
                : (currentMode == ThemeMode.dark ? Brightness.dark : null),
            primaryColor: CupertinoColors.label,
            textTheme: const CupertinoTextThemeData(
              textStyle: TextStyle(fontFamily: '.SF Pro Text'),
            ),
          ),
          home: const AttendanceApp(),
          debugShowCheckedModeBanner: false,
        );
      },
    );
  }
}

class Student {
  String uid, name, roll;
  Student(this.uid, this.name, this.roll);
}

// --- Animated List Item wrapper (fade + slide in) -----------------------------------
class _FadeSlideIn extends StatefulWidget {
  final Widget child;
  final int index;
  final Duration baseDuration;

  const _FadeSlideIn({
    required this.child,
    this.index = 0,
    this.baseDuration = const Duration(milliseconds: 320),
  });

  @override
  State<_FadeSlideIn> createState() => _FadeSlideInState();
}

class _FadeSlideInState extends State<_FadeSlideIn>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _opacity;
  late Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    final delay = Duration(milliseconds: widget.index * 40);
    _controller = AnimationController(
      vsync: this,
      duration: widget.baseDuration,
    );
    _opacity = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.06),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
    Future.delayed(delay, () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _opacity,
    child: SlideTransition(position: _slide, child: widget.child),
  );
}

// --- Animated status badge (cross‑fades between PRESENT / ABSENT) ------------------
class _AnimatedStatusBadge extends StatefulWidget {
  final bool present;
  const _AnimatedStatusBadge({required this.present});

  @override
  State<_AnimatedStatusBadge> createState() => _AnimatedStatusBadgeState();
}

class _AnimatedStatusBadgeState extends State<_AnimatedStatusBadge>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _scale = Tween(
      begin: 0.85,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutBack));
    _ctrl.forward();
  }

  @override
  void didUpdateWidget(_AnimatedStatusBadge old) {
    super.didUpdateWidget(old);
    if (old.present != widget.present) {
      _ctrl.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: _scale,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: widget.present
              ? const Color(0xFFDCFCE7)
              : const Color(0xFFFEE2E2),
          borderRadius: BorderRadius.circular(4),
        ),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: Text(
            widget.present ? "PRESENT" : "ABSENT",
            key: ValueKey(widget.present),
            style: AppTextStyles.badge(context).copyWith(
              color: widget.present
                  ? const Color(0xFF166534)
                  : const Color(0xFF991B1B),
            ),
          ),
        ),
      ),
    );
  }
}

// --- Spring‑pressed button wrapper (iOS style) ------------------------------------
class _SpringButton extends StatefulWidget {
  final Widget child;
  final VoidCallback? onPressed;

  const _SpringButton({super.key, required this.child, this.onPressed});

  @override
  State<_SpringButton> createState() => _SpringButtonState();
}

class _SpringButtonState extends State<_SpringButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
    );
    _scale = Tween(
      begin: 1.0,
      end: 0.94,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _ctrl.forward(),
      onTapUp: (_) {
        _ctrl.reverse();
        widget.onPressed?.call();
      },
      onTapCancel: () => _ctrl.reverse(),
      child: ScaleTransition(scale: _scale, child: widget.child),
    );
  }
}

// --- Main App ---------------------------------------------------------------------
class AttendanceApp extends StatefulWidget {
  const AttendanceApp({super.key});
  @override
  State<AttendanceApp> createState() => _AttendanceAppState();
}

class _AttendanceAppState extends State<AttendanceApp>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  // WebSocket connection to the ESP8266 (replaces the BLE device/characteristic)
  WebSocketChannel? channel;
  WebSocketChannel? _pendingChannel;
  StreamSubscription? _wsSub;
  bool _connectCancelled = false;

  Map<String, Student> allStudents = {};
  Set<String> presentToday = {};
  List<Student> historyResults = [];
  bool isAttOpen = true, isConnecting = false, isHistorySyncing = false;
  String detectedUID = "---";

  // Track removals for exit animation
  final Set<String> _removingStudents = {};

  // Sync animation
  bool _isSyncing = false;
  late AnimationController _syncRotationController;

  final TextEditingController nameC = TextEditingController();
  final TextEditingController rollC = TextEditingController();

  bool get isConnected => channel != null;

  // Send a text command to the scanner
  void send(String cmd) {
    try {
      channel?.sink.add(cmd);
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    themeNotifier.addListener(_onThemeChanged);
    _syncRotationController =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 800),
        )..addStatusListener((status) {
          if (status == AnimationStatus.completed) {
            _syncRotationController.repeat();
          }
        });
  }

  void _onThemeChanged() => setState(() {});

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _wsSub?.cancel();
    channel?.sink.close();
    _pendingChannel?.sink.close();
    themeNotifier.removeListener(_onThemeChanged);
    _syncRotationController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      channel?.sink.close();
    }
  }

  // Connect to the ESP8266 over WebSocket
  Future<void> connect() async {
    HapticFeedback.mediumImpact();
    _connectCancelled = false;
    setState(() => isConnecting = true);

    final ch = WebSocketChannel.connect(
      Uri.parse('ws://$kDeviceHost:$kDevicePort'),
    );
    _pendingChannel = ch;

    try {
      await ch.ready.timeout(const Duration(seconds: 6));
      if (_connectCancelled || !mounted) {
        ch.sink.close();
        return;
      }
      _pendingChannel = null;
      channel = ch;
      _wsSub = ch.stream.listen(
        handleData,
        onDone: _handleDisconnect,
        onError: (_) => _handleDisconnect(),
      );
      setState(() => isConnecting = false);
      HapticFeedback.lightImpact();
      syncEverything();
    } catch (_) {
      ch.sink.close();
      _pendingChannel = null;
      if (_connectCancelled || !mounted) return;
      setState(() => isConnecting = false);
      HapticFeedback.heavyImpact();
      _showConnectError();
    }
  }

  void _showConnectError() {
    showCupertinoDialog(
      context: context,
      builder: (c) => CupertinoAlertDialog(
        title: const Text("Can't reach scanner"),
        content: const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text(
            "Connect your phone to the \"ESP_Attendance\" WiFi network first. "
            "If it still fails, turn off mobile data and try again.",
          ),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(c),
            child: const Text("OK"),
          ),
        ],
      ),
    );
  }

  // Called when the socket closes or errors (replaces BLE disconnected state)
  void _handleDisconnect() {
    _wsSub?.cancel();
    _wsSub = null;
    if (channel == null || !mounted) return;
    setState(() {
      channel = null;
      presentToday.clear();
      allStudents.clear();
      historyResults.clear();
      isAttOpen = true;
      detectedUID = "---";
      isConnecting = false;
      isHistorySyncing = false;
      _isSyncing = false;
    });
    _syncRotationController.stop();
    HapticFeedback.heavyImpact();
  }

  // Cancel an in-progress connection attempt
  void cancelConnect() {
    _connectCancelled = true;
    _pendingChannel?.sink.close();
    _pendingChannel = null;
    HapticFeedback.lightImpact();
    setState(() => isConnecting = false);
  }

  void syncEverything() {
    HapticFeedback.lightImpact();
    _startSyncAnimation();
    send("TIME:${DateTime.now().millisecondsSinceEpoch ~/ 1000}");
    send("GET_STATUS");
    send("GET_STUDENTS");
    send("GET_TODAY");
    // Stop animation after a delay (since we don't have a clear "sync done" event)
    Future.delayed(const Duration(seconds: 2), () => _stopSyncAnimation());
  }

  void _startSyncAnimation() {
    if (mounted) {
      setState(() => _isSyncing = true);
      _syncRotationController.forward();
    }
  }

  void _stopSyncAnimation() {
    if (mounted) {
      setState(() => _isSyncing = false);
      _syncRotationController.stop();
    }
  }

  void handleData(dynamic data) {
    String msg = (data is String ? data : utf8.decode(data as List<int>))
        .trim();
    if (msg.startsWith("DUP:")) {
      // Card already assigned to a student (scanned during registration)
      String uid = msg.substring(4);
      dupSignal.value = null;
      dupSignal.value = allStudents[uid]?.name ?? "another student";
    } else if (msg.startsWith("ERR:DUP")) {
      // Firmware refused an ADD because the card is already registered
      HapticFeedback.heavyImpact();
      syncEverything();
      showCupertinoDialog(
        context: context,
        builder: (c) => CupertinoAlertDialog(
          title: const Text("Card already registered"),
          content: const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text("This card is already assigned to another student."),
          ),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(c),
              child: const Text("OK"),
            ),
          ],
        ),
      );
    } else if (msg.startsWith("NEW_UID:")) {
      String uid = msg.substring(8);
      if (allStudents.containsKey(uid)) {
        dupSignal.value = null;
        dupSignal.value = allStudents[uid]!.name;
        return;
      }
      detectedUID = uid;
      scanSignal.value = uid;
    } else if (msg.startsWith("LIVE:") || msg.startsWith("TOD:")) {
      if (!msg.contains("END")) {
        HapticFeedback.selectionClick();
        setState(() => presentToday.add(msg.substring(msg.indexOf(':') + 1)));
      }
    } else if (msg.startsWith("STU:")) {
      if (msg == "STU:END") return;
      var p = msg.substring(4).split(',');
      if (p.length >= 3) {
        setState(() {
          allStudents[p[0]] = Student(p[0], p[1], p[2]);
        });
      }
    } else if (msg.startsWith("STAT:")) {
      setState(() => isAttOpen = msg.contains("OPEN"));
    } else if (msg.startsWith("HIS:")) {
      if (msg == "HIS:END") {
        setState(() => isHistorySyncing = false);
        return;
      }
      String uid = msg.substring(4);
      if (allStudents.containsKey(uid)) {
        setState(() => historyResults.add(allStudents[uid]!));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoTabScaffold(
      tabBar: CupertinoTabBar(
        backgroundColor: ZincColors.surface(context),
        activeColor: ZincColors.text(context),
        border: Border(
          top: BorderSide(color: ZincColors.border(context), width: 0.5),
        ),
        items: const [
          BottomNavigationBarItem(
            icon: Icon(CupertinoIcons.square_list),
            label: "Live",
          ),
          BottomNavigationBarItem(
            icon: Icon(CupertinoIcons.person_2),
            label: "Directory",
          ),
          BottomNavigationBarItem(
            icon: Icon(CupertinoIcons.archivebox),
            label: "History",
          ),
        ],
      ),
      tabBuilder: (context, i) {
        return CupertinoPageScaffold(
          backgroundColor: ZincColors.background(context),
          navigationBar: CupertinoNavigationBar(
            backgroundColor: ZincColors.surface(context).withAlpha(234),
            border: Border(
              bottom: BorderSide(color: ZincColors.border(context), width: 0.5),
            ),
            leading: CupertinoButton(
              padding: EdgeInsets.zero,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                transitionBuilder: (child, anim) => ScaleTransition(
                  scale: anim,
                  child: FadeTransition(opacity: anim, child: child),
                ),
                child: Icon(
                  ZincColors.getBrightness(context) == Brightness.dark
                      ? CupertinoIcons.moon_fill
                      : CupertinoIcons.sun_max_fill,
                  key: ValueKey(ZincColors.getBrightness(context)),
                  size: 20,
                  color: ZincColors.text(context),
                ),
              ),
              onPressed: () {
                HapticFeedback.lightImpact();
                themeNotifier.value = themeNotifier.value == ThemeMode.light
                    ? ThemeMode.dark
                    : ThemeMode.light;
              },
            ),
            middle: Text(
              ["Attendance Board", "Student List", "History Archive"][i],
              style: AppTextStyles.title(context),
            ),
            trailing: isConnected
                ? CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: () {
                      if (!_isSyncing) syncEverything();
                    },
                    child: AnimatedBuilder(
                      animation: _syncRotationController,
                      builder: (context, _) => Transform.rotate(
                        angle: _syncRotationController.value * 2 * math.pi,
                        child: SizedBox(
                          width: 24,
                          height: 24,
                          child: Icon(
                            _isSyncing
                                ? CupertinoIcons.arrow_2_circlepath_circle_fill
                                : CupertinoIcons.arrow_2_circlepath,
                            size: 20,
                            color: _isSyncing
                                ? ZincColors.text(context)
                                : ZincColors.mutedText(context),
                          ),
                        ),
                      ),
                    ),
                  )
                : null,
          ),
          child: SafeArea(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 350),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, 0.03),
                    end: Offset.zero,
                  ).animate(animation),
                  child: child,
                ),
              ),
              child: !isConnected
                  ? _buildConnect()
                  : [_todayTab(), _manageTab(), _historyTab()][i],
            ),
          ),
        );
      },
    );
  }

  Widget _buildConnect() {
    return Center(
      key: const ValueKey('connect'),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _PulsingIcon(
            icon: CupertinoIcons.wifi,
            color: ZincColors.mutedText(context),
            size: 54,
          ),
          const SizedBox(height: AppSpacing.md),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              "Join the \"ESP_Attendance\" WiFi network,\nthen tap Connect.",
              textAlign: TextAlign.center,
              style: AppTextStyles.caption(context),
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          _SpringButton(
            onPressed: isConnecting ? null : connect,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeInOutCubicEmphasized,
              height: 48,
              width: isConnecting ? 48 : 190,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: ZincColors.text(context),
                borderRadius: BorderRadius.circular(isConnecting ? 24 : 14),
              ),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 150),
                transitionBuilder: (child, animation) =>
                    FadeTransition(opacity: animation, child: child),
                child: isConnecting
                    ? CupertinoActivityIndicator(
                        key: const ValueKey("loader"),
                        color: ZincColors.background(context),
                      )
                    : Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Text(
                          "Connect Scanner",
                          key: const ValueKey('label'),
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.fade,
                          style: AppTextStyles.title(context).copyWith(
                            color: ZincColors.background(context),
                            fontSize: 16,
                          ),
                        ),
                      ),
              ),
            ),
          ),
          // ← Cancel button fades in while connecting
          AnimatedOpacity(
            duration: const Duration(milliseconds: 250),
            opacity: isConnecting ? 1.0 : 0.0,
            child: Padding(
              padding: const EdgeInsets.only(top: 16),
              child: CupertinoButton(
                onPressed: isConnecting ? cancelConnect : null,
                child: Text(
                  "Cancel",
                  style: AppTextStyles.body(
                    context,
                  ).copyWith(color: ZincColors.mutedText(context)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _todayTab() {
    List<Student> students = allStudents.values.toList()
      ..sort((a, b) => a.roll.compareTo(b.roll));

    return ListView(
      key: const ValueKey('today'),
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
      children: [
        _FadeSlideIn(
          index: 0,
          child: _buildZincCard(
            child: _AnimatedStatusCard(
              isAttOpen: isAttOpen,
              onStop: () {
                HapticFeedback.mediumImpact();
                send("STOP_ATT");
                setState(() => isAttOpen = false);
              },
              onContinue: () {
                HapticFeedback.mediumImpact();
                setState(() => isAttOpen = true);
                send("RESUME_ATT");
              },
              onFreshStart: () {
                HapticFeedback.heavyImpact();
                setState(() {
                  presentToday.clear();
                  isAttOpen = true;
                });
                send("START_ATT");
              },
              context: context,
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        _FadeSlideIn(
          index: 1,
          child: _buildAnimatedTable(
            headers: const ["Roll", "Name", "Status"],
            rows: students.asMap().entries.map((entry) {
              int idx = entry.key;
              Student s = entry.value;
              bool present = presentToday.contains(s.uid);
              return _AnimatedTableRow(
                key: ValueKey("row_${s.uid}"),
                index: idx,
                cells: [
                  Text(s.roll, style: AppTextStyles.body(context)),
                  Text(
                    s.name,
                    style: AppTextStyles.body(
                      context,
                    ).copyWith(fontWeight: FontWeight.bold),
                  ),
                  _AnimatedStatusBadge(present: present),
                ],
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  Widget _manageTab() {
    final students = allStudents.values.toList()
      ..sort((a, b) => a.roll.compareTo(b.roll));

    return Stack(
      key: const ValueKey('manage'),
      children: [
        ListView(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 100),
          children: [
            _FadeSlideIn(
              index: 0,
              child: _buildAnimatedTable(
                headers: const ["Name", "Roll", ""],
                rows: students.asMap().entries.map((entry) {
                  int idx = entry.key;
                  Student s = entry.value;
                  final isRemoving = _removingStudents.contains(s.uid);
                  return _AnimatedTableRow(
                    key: ValueKey("dir_${s.uid}"),
                    index: idx,
                    compact: true,
                    cells: [
                      Text(
                        s.name,
                        style: AppTextStyles.body(
                          context,
                        ).copyWith(fontWeight: FontWeight.bold),
                      ),
                      Text(s.roll, style: AppTextStyles.body(context)),
                      CupertinoButton(
                        padding: EdgeInsets.zero,
                        onPressed: isRemoving
                            ? null
                            : () async {
                                HapticFeedback.mediumImpact();
                                setState(() => _removingStudents.add(s.uid));
                              },
                        minimumSize: Size(28, 28),
                        child: const Icon(
                          CupertinoIcons.trash,
                          size: 16,
                          color: CupertinoColors.destructiveRed,
                        ),
                      ),
                    ],
                    isRemoving: isRemoving,
                    onRemovalComplete: () {
                      send("DEL:${s.uid}");
                      setState(() {
                        _removingStudents.remove(s.uid);
                        allStudents.remove(s.uid);
                      });
                    },
                  );
                }).toList(),
              ),
            ),
          ],
        ),
        Positioned(
          bottom: 24,
          right: 20,
          child: _FadeSlideIn(
            index: 2,
            baseDuration: const Duration(milliseconds: 450),
            child: _SpringButton(
              onPressed: _openAddStudentModal,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  color: ZincColors.text(context),
                  borderRadius: BorderRadius.circular(32),
                  boxShadow: [
                    BoxShadow(
                      color: ZincColors.text(context).withAlpha(63),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      CupertinoIcons.add,
                      color: ZincColors.background(context),
                      size: 18,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Text(
                      "Add Student",
                      style: AppTextStyles.title(context).copyWith(
                        color: ZincColors.background(context),
                        fontSize: 15,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _historyTab() {
    DateTime selected = DateTime.now();
    return Column(
      key: const ValueKey('history'),
      children: [
        const SizedBox(height: AppSpacing.lg),
        _FadeSlideIn(
          index: 0,
          child: Padding(
            padding: AppSpacing.screenHorizontal,
            child: _SpringButton(
              onPressed: () {
                showCupertinoModalPopup(
                  context: context,
                  builder: (context) => Container(
                    height: 320,
                    color: ZincColors.background(context),
                    child: Column(
                      children: [
                        Container(
                          color: ZincColors.surface(context),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                "Select Date",
                                style: AppTextStyles.title(context),
                              ),
                              CupertinoButton(
                                padding: EdgeInsets.zero,
                                child: Text(
                                  "Done",
                                  style: AppTextStyles.title(
                                    context,
                                  ).copyWith(color: ZincColors.text(context)),
                                ),
                                onPressed: () {
                                  HapticFeedback.mediumImpact();
                                  setState(() {
                                    historyResults.clear();
                                    isHistorySyncing = true;
                                  });
                                  send(
                                    "GET_HIST:${DateFormat('dd-MM-yyyy').format(selected)}",
                                  );
                                  Navigator.pop(context);
                                },
                              ),
                            ],
                          ),
                        ),
                        Expanded(
                          child: CupertinoDatePicker(
                            mode: CupertinoDatePickerMode.date,
                            initialDateTime: selected,
                            onDateTimeChanged: (d) => selected = d,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 14),
                decoration: BoxDecoration(
                  color: ZincColors.surface(context),
                  border: Border.all(color: ZincColors.border(context)),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      CupertinoIcons.calendar,
                      color: ZincColors.text(context),
                      size: 18,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Text(
                      "Query Date Archive",
                      style: AppTextStyles.body(
                        context,
                      ).copyWith(fontWeight: FontWeight.w600, fontSize: 15),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          height: isHistorySyncing ? 44 : 16,
          curve: Curves.easeOutCubic,
          child: Center(
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 250),
              opacity: isHistorySyncing ? 1.0 : 0.0,
              child: const CupertinoActivityIndicator(),
            ),
          ),
        ),
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            switchInCurve: Curves.easeOutCubic,
            child: historyResults.isEmpty
                ? Center(
                    key: const ValueKey('empty'),
                    child: Text(
                      isHistorySyncing
                          ? "Loading..."
                          : "Select a date to view records",
                      style: AppTextStyles.caption(
                        context,
                      ).copyWith(fontSize: 14),
                    ),
                  )
                : ListView(
                    key: const ValueKey('results'),
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                    children: [
                      _buildAnimatedTable(
                        headers: const ["Roll", "Name", "UID"],
                        rows: historyResults.asMap().entries.map((entry) {
                          int idx = entry.key;
                          Student s = entry.value;
                          return _AnimatedTableRow(
                            key: ValueKey("hist_${s.uid}"),
                            index: idx,
                            cells: [
                              Text(s.roll, style: AppTextStyles.body(context)),
                              Text(
                                s.name,
                                style: AppTextStyles.body(
                                  context,
                                ).copyWith(fontWeight: FontWeight.bold),
                              ),
                              Text(
                                s.uid,
                                style: AppTextStyles.caption(
                                  context,
                                ).copyWith(fontFamily: 'Courier'),
                              ),
                            ],
                          );
                        }).toList(),
                      ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }

  void _openAddStudentModal() {
    detectedUID = "---";
    scanSignal.value = null;
    nameC.clear();
    rollC.clear();
    showCupertinoModalPopup(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) {
          return TweenAnimationBuilder<double>(
            tween: Tween(begin: 0.0, end: 1.0),
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
            builder: (context, value, child) => Transform.translate(
              offset: Offset(0, (1 - value) * 50),
              child: Opacity(opacity: value, child: child),
            ),
            child: Container(
              height: MediaQuery.of(context).size.height * 0.62,
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
              decoration: BoxDecoration(
                color: ZincColors.surface(context),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(20),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 20),
                      decoration: BoxDecoration(
                        color: ZincColors.border(context),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        "New Registration",
                        style: AppTextStyles.headline(context),
                      ),
                      CupertinoButton(
                        padding: EdgeInsets.zero,
                        onPressed: () => Navigator.pop(context),
                        minimumSize: Size(30, 30),
                        child: Icon(
                          CupertinoIcons.xmark_circle_fill,
                          color: ZincColors.mutedText(context),
                          size: 26,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  CupertinoTextField(
                    controller: nameC,
                    placeholder: "Student Name",
                    style: AppTextStyles.body(context),
                    decoration: _fieldBox(context),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 14,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  CupertinoTextField(
                    controller: rollC,
                    placeholder: "Roll Number",
                    style: AppTextStyles.body(context),
                    decoration: _fieldBox(context),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 14,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeOutCubic,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: ZincColors.background(context).withAlpha(127),
                      border: Border.all(
                        color: detectedUID != "---"
                            ? const Color(0xFF86EFAC)
                            : ZincColors.border(context),
                      ),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 250),
                          transitionBuilder: (child, anim) => ScaleTransition(
                            scale: anim,
                            child: FadeTransition(opacity: anim, child: child),
                          ),
                          child: Icon(
                            detectedUID == "---"
                                ? CupertinoIcons.creditcard
                                : CupertinoIcons.check_mark_circled_solid,
                            key: ValueKey(detectedUID == "---"),
                            color: detectedUID == "---"
                                ? ZincColors.mutedText(context)
                                : CupertinoColors.activeGreen,
                            size: 22,
                          ),
                        ),
                        const SizedBox(width: AppSpacing.md),
                        Expanded(
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 250),
                            child: Text(
                              detectedUID == "---"
                                  ? "No card detected"
                                  : "UID: $detectedUID",
                              key: ValueKey(detectedUID),
                              style: AppTextStyles.body(context).copyWith(
                                fontFamily: 'Courier',
                                color: ZincColors.mutedText(context),
                              ),
                            ),
                          ),
                        ),
                        CupertinoButton(
                          padding: EdgeInsets.zero,
                          onPressed: () async {
                            scanSignal.value = null;
                            dupSignal.value = null;
                            send("PREP_REG");
                            await showCupertinoModalPopup(
                              context: context,
                              builder: (c) => const _PulseDialog(),
                            );
                            setModalState(
                              () => detectedUID = scanSignal.value ?? "---",
                            );
                          },
                          minimumSize: Size(30, 30),
                          child: Text(
                            detectedUID == "---" ? "Scan Card" : "Rescan",
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  _SpringButton(
                    onPressed: (detectedUID == "---")
                        ? null
                        : () {
                            HapticFeedback.mediumImpact();
                            send(
                              "ADD:$detectedUID,${nameC.text},${rollC.text}",
                            );
                            syncEverything();
                            Navigator.pop(context);
                          },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeOutCubic,
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 15),
                      decoration: BoxDecoration(
                        color: detectedUID == "---"
                            ? ZincColors.mutedText(context).withAlpha(102)
                            : ZincColors.text(context),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Center(
                        child: Text(
                          "Finalize Registration",
                          style: AppTextStyles.title(context).copyWith(
                            color: ZincColors.background(context),
                            fontSize: 16,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildAnimatedTable({
    required List<String> headers,
    required List<_AnimatedTableRow> rows,
  }) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: ZincColors.border(context)),
        borderRadius: BorderRadius.circular(10),
        color: ZincColors.surface(context),
      ),
      clipBehavior: Clip.hardEdge,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: ZincColors.text(context).withAlpha(10),
            child: Row(
              children: headers.asMap().entries.map((e) {
                bool isLast = e.key == headers.length - 1;
                bool isFirst = e.key == 0;
                return Expanded(
                  flex: isFirst || isLast ? 0 : 1,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    child: Text(
                      e.value,
                      style: AppTextStyles.caption(context).copyWith(
                        fontWeight: FontWeight.w900,
                        color: ZincColors.text(context),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          Container(height: 0.5, color: ZincColors.border(context)),
          ...rows,
        ],
      ),
    );
  }

  Widget _buildZincCard({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: ZincColors.surface(context),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: ZincColors.border(context)),
      ),
      child: child,
    );
  }

  BoxDecoration _fieldBox(BuildContext context) => BoxDecoration(
    color: ZincColors.background(context).withAlpha(127),
    border: Border.all(color: ZincColors.border(context)),
    borderRadius: BorderRadius.circular(10),
  );
}

class _AnimatedTableRow extends StatefulWidget {
  final List<Widget> cells;
  final int index;
  final bool compact;
  final bool isRemoving;
  final VoidCallback? onRemovalComplete;

  const _AnimatedTableRow({
    super.key,
    required this.cells,
    this.index = 0,
    this.compact = false,
    this.isRemoving = false,
    this.onRemovalComplete,
  });

  @override
  State<_AnimatedTableRow> createState() => _AnimatedTableRowState();
}

class _AnimatedTableRowState extends State<_AnimatedTableRow>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _opacity;
  late Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );
    _opacity = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.05),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));

    final delay = Duration(milliseconds: 60 + widget.index * 35);
    Future.delayed(delay, () {
      if (mounted) _ctrl.forward();
    });
  }

  @override
  void didUpdateWidget(_AnimatedTableRow old) {
    super.didUpdateWidget(old);
    if (widget.isRemoving && !old.isRemoving) {
      _ctrl.reverse().then((_) {
        widget.onRemovalComplete?.call();
      });
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizeTransition(
      sizeFactor: _opacity,
      axisAlignment: -1.0,
      child: FadeTransition(
        opacity: _opacity,
        child: SlideTransition(
          position: _slide,
          child: Container(
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: ZincColors.border(context),
                  width: 0.5,
                ),
              ),
            ),
            child: Row(
              children: widget.cells.asMap().entries.map((e) {
                bool isLast = e.key == widget.cells.length - 1;
                bool isFirst = e.key == 0;
                return Expanded(
                  flex: isFirst || isLast ? 0 : 1,
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: widget.compact ? 10 : 14,
                    ),
                    child: e.value,
                  ),
                );
              }).toList(),
            ),
          ),
        ),
      ),
    );
  }
}

class _AnimatedStatusCard extends StatefulWidget {
  final bool isAttOpen;
  final VoidCallback onStop;
  final VoidCallback onContinue;
  final VoidCallback onFreshStart;
  final BuildContext context;

  const _AnimatedStatusCard({
    required this.isAttOpen,
    required this.onStop,
    required this.onContinue,
    required this.onFreshStart,
    required this.context,
  });

  @override
  State<_AnimatedStatusCard> createState() => _AnimatedStatusCardState();
}

class _AnimatedStatusCardState extends State<_AnimatedStatusCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _bounceController;

  @override
  void initState() {
    super.initState();
    _bounceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
  }

  @override
  void didUpdateWidget(_AnimatedStatusCard old) {
    super.didUpdateWidget(old);
    if (old.isAttOpen != widget.isAttOpen) {
      _bounceController.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _bounceController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext outerContext) {
    return ScaleTransition(
      scale: Tween(begin: 0.98, end: 1.0).animate(
        CurvedAnimation(parent: _bounceController, curve: Curves.elasticOut),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "Current State",
                    style: AppTextStyles.caption(
                      widget.context,
                    ).copyWith(fontWeight: FontWeight.bold, letterSpacing: 0.5),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        transitionBuilder: (child, anim) => ScaleTransition(
                          scale: anim,
                          child: FadeTransition(opacity: anim, child: child),
                        ),
                        child: Icon(
                          widget.isAttOpen
                              ? CupertinoIcons.circle_fill
                              : CupertinoIcons.stop_circle,
                          key: ValueKey(widget.isAttOpen),
                          size: 10,
                          color: widget.isAttOpen
                              ? CupertinoColors.activeGreen
                              : CupertinoColors.destructiveRed,
                        ),
                      ),
                      const SizedBox(width: 6),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 250),
                        child: Text(
                          widget.isAttOpen ? "RECORDING" : "STOPPED",
                          key: ValueKey(widget.isAttOpen),
                          style: AppTextStyles.headline(
                            widget.context,
                          ).copyWith(fontSize: 18, fontWeight: FontWeight.w900),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: widget.isAttOpen
                    ? _SpringButton(
                        key: const ValueKey('stop'),
                        onPressed: widget.onStop,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: CupertinoColors.destructiveRed,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Text(
                            "Stop",
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                              color: CupertinoColors.white,
                            ),
                          ),
                        ),
                      )
                    : const SizedBox.shrink(key: ValueKey('none')),
              ),
            ],
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeOutCubic,
            child: widget.isAttOpen
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: _SpringButton(
                            onPressed: widget.onContinue,
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              decoration: BoxDecoration(
                                color: CupertinoColors.activeGreen,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: const Center(
                                child: Text(
                                  "Continue",
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13,
                                    color: CupertinoColors.white,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _SpringButton(
                            onPressed: widget.onFreshStart,
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              decoration: BoxDecoration(
                                color: ZincColors.text(widget.context),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Center(
                                child: Text(
                                  "Fresh Start",
                                  style: AppTextStyles.body(widget.context)
                                      .copyWith(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 13,
                                        color: ZincColors.background(
                                          widget.context,
                                        ),
                                      ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _PulsingIcon extends StatefulWidget {
  final IconData icon;
  final Color color;
  final double size;

  const _PulsingIcon({
    required this.icon,
    required this.color,
    required this.size,
  });

  @override
  State<_PulsingIcon> createState() => _PulsingIconState();
}

class _PulsingIconState extends State<_PulsingIcon>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
    _scale = Tween(
      begin: 0.9,
      end: 1.1,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: _scale,
      child: Icon(widget.icon, size: widget.size, color: widget.color),
    );
  }
}

class _PulseDialog extends StatefulWidget {
  const _PulseDialog();
  @override
  State<_PulseDialog> createState() => _PulseDialogState();
}

class _PulseDialogState extends State<_PulseDialog>
    with SingleTickerProviderStateMixin {
  late AnimationController _c;
  bool isFinished = false;
  bool isDuplicate = false;
  String dupName = "";

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);
    scanSignal.addListener(_onScanReceived);
    dupSignal.addListener(_onDuplicate);
  }

  void _onDuplicate() async {
    if (dupSignal.value == null || !mounted) return;
    HapticFeedback.heavyImpact();
    setState(() {
      isDuplicate = true;
      dupName = dupSignal.value!;
    });
    await Future.delayed(const Duration(milliseconds: 2000));
    if (mounted) setState(() => isDuplicate = false);
  }

  void _onScanReceived() async {
    if (scanSignal.value != null && mounted) {
      HapticFeedback.heavyImpact();
      setState(() => isFinished = true);
      _c.stop();
      _c.duration = const Duration(milliseconds: 300);
      _c.forward(from: 0.5);
      await Future.delayed(const Duration(milliseconds: 1200));
      if (mounted) Navigator.pop(context);
    }
  }

  @override
  void dispose() {
    scanSignal.removeListener(_onScanReceived);
    dupSignal.removeListener(_onDuplicate);
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Color activeColor = isDuplicate
        ? CupertinoColors.destructiveRed
        : (isFinished
              ? CupertinoColors.activeGreen
              : ZincColors.text(context));
    IconData activeIcon = isDuplicate
        ? CupertinoIcons.xmark_circle_fill
        : (isFinished
              ? CupertinoIcons.check_mark_circled_solid
              : CupertinoIcons.radiowaves_left);

    return CupertinoActionSheet(
      title: AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        child: Text(
          isDuplicate
              ? "Already Registered"
              : (isFinished ? "Success!" : "Ready to Sync"),
          key: ValueKey("$isFinished$isDuplicate"),
          style: AppTextStyles.title(context),
        ),
      ),
      message: Column(
        children: [
          const SizedBox(height: AppSpacing.xxl),
          AnimatedBuilder(
            animation: _c,
            builder: (context, child) {
              double scale = isFinished
                  ? (1.0 + (_c.value * 0.4))
                  : (1.0 + (_c.value * 0.25));
              return Transform.scale(
                scale: scale,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  transitionBuilder: (child, anim) => ScaleTransition(
                    scale: anim,
                    child: FadeTransition(opacity: anim, child: child),
                  ),
                  child: Icon(
                    activeIcon,
                    key: ValueKey(activeIcon),
                    size: 50,
                    color: activeColor,
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: AppSpacing.xxl),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            child: Text(
              isDuplicate
                  ? "This card belongs to $dupName.\nTap a different card."
                  : (isFinished
                        ? "UID Captured: ${scanSignal.value}"
                        : "Tap the student card on the RFID reader."),
              textAlign: TextAlign.center,
              key: ValueKey("$isFinished$isDuplicate"),
              style: AppTextStyles.caption(context),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
      ),
      cancelButton: CupertinoActionSheetAction(
        isDestructiveAction: true,
        onPressed: () => Navigator.pop(context),
        child: Text(
          "Cancel",
          style: AppTextStyles.body(
            context,
          ).copyWith(color: ZincColors.text(context)),
        ),
      ),
    );
  }
}