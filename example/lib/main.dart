import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:zairn_sdk/zairn_sdk.dart';

// ============================================================
// Minimal foreground task handler (keep-alive only, no GPS here)
// ============================================================

@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(_KeepAliveHandler());
}

class _KeepAliveHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}
  @override
  void onRepeatEvent(DateTime timestamp) {}
  @override
  Future<void> onDestroy(DateTime timestamp) async {}
}

// ============================================================
// App
// ============================================================

void main() => runApp(const ZairnExampleApp());

class ZairnExampleApp extends StatelessWidget {
  const ZairnExampleApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Zairn Trace Collector',
      theme: ThemeData(colorSchemeSeed: const Color(0xFF6442D6), useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: const Color(0xFF6442D6), brightness: Brightness.dark, useMaterial3: true),
      home: const TraceCollectorPage(),
    );
  }
}

// ============================================================
// Main Page
// ============================================================

class TraceCollectorPage extends StatefulWidget {
  const TraceCollectorPage({super.key});
  @override
  State<TraceCollectorPage> createState() => _TraceCollectorPageState();
}

class _TraceCollectorPageState extends State<TraceCollectorPage> with WidgetsBindingObserver {
  bool _isCollecting = false;
  int _pointCount = 0;
  int _intervalSeconds = 60;
  Map<String, dynamic>? _lastPoint;

  // Android: GPS stream (protected by foreground service)
  StreamSubscription<Position>? _posStream;
  int _lastRecordedTs = 0;

  // iOS: native CLLocationManager via platform channel
  static const _iosChannel = MethodChannel('zairn/ios_location');
  static const _iosEvents = EventChannel('zairn/ios_location_events');
  StreamSubscription? _iosEventSub;

  PrivacyProcessor? _privacyProcessor;
  LocationState? _lastPrivacyState;
  bool _lowPowerMode = false;

  // File-based storage (not SharedPreferences — avoids OOM)
  File? _traceFile;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initTraceFile();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _posStream?.cancel();
    _iosEventSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      // Release Dart-side resources to reduce memory pressure
      _privacyProcessor = null; // Will be recreated on next point
      _lastPrivacyState = null;
      // Don't clear _lastPoint — it's tiny and useful on resume
      debugPrint('[Zairn] Background: released Dart resources');
    }
    if (state == AppLifecycleState.resumed) {
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) {
          _reloadPointCount();
        }
      });
    }
  }

  Future<void> _reloadPointCount() async {
    try {
      if (_traceFile == null || !await _traceFile!.exists()) return;
      final bytes = await _traceFile!.length();
      if (bytes == 0) return;
      // Estimate count from file size (~150 bytes per line)
      // Avoids reading the entire file on resume
      final estimated = bytes ~/ 150;
      if (mounted) {
        setState(() => _pointCount = estimated);
      }
    } catch (e) {
      debugPrint('Reload error: $e');
    }
  }

  Future<void> _initTraceFile() async {
    final dir = await getApplicationDocumentsDirectory();
    _traceFile = File('${dir.path}/dense-trace.jsonl');
    if (await _traceFile!.exists()) {
      // Estimate point count from file size (avoid reading entire file)
      final bytes = await _traceFile!.length();
      _pointCount = bytes > 0 ? bytes ~/ 150 : 0;

      // Read only the last line for display (read last 300 bytes)
      if (bytes > 0) {
        try {
          final raf = await _traceFile!.open(mode: FileMode.read);
          final readFrom = bytes > 300 ? bytes - 300 : 0;
          await raf.setPosition(readFrom);
          final tail = await raf.read(300);
          await raf.close();
          final tailStr = utf8.decode(tail, allowMalformed: true);
          final lines = tailStr.split('\n').where((l) => l.trim().isNotEmpty).toList();
          if (lines.isNotEmpty) {
            final decoded = jsonDecode(lines.last);
            _lastPoint = _normalizePoint(decoded);
          }
        } catch (_) {}
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _appendPoint(Map<String, dynamic> point) async {
    if (_traceFile == null) return;
    await _traceFile!.writeAsString('${jsonEncode(point)}\n', mode: FileMode.append);
    _pointCount++;
    _lastPoint = _normalizePoint(point);
  }

  Map<String, dynamic>? _normalizePoint(dynamic raw) {
    if (raw is! Map) return null;
    final point = Map<String, dynamic>.from(raw);
    final lat = point['lat'] ?? point['latitude'];
    final lon = point['lon'] ?? point['longitude'];
    if (lat != null) point['lat'] = lat;
    if (lon != null) point['lon'] = lon;
    return point;
  }

  // =====================
  // Start / Stop
  // =====================

  Future<void> _start() async {
    if (_isCollecting) return;

    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        _showSnackBar('GPS disabled. Enable location services.');
        return;
      }

      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        _showSnackBar('Location permission required. Opening settings...');
        await Geolocator.openAppSettings();
        return;
      }

      // Android: start foreground service for keep-alive
      if (Platform.isAndroid) {
        await _startAndroidService();
      }

      if (Platform.isAndroid) {
        // Android: GPS stream protected by foreground service
        _posStream = Geolocator.getPositionStream(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 0),
        ).listen((pos) {
          final now = DateTime.now().millisecondsSinceEpoch;
          if (now - _lastRecordedTs >= _intervalSeconds * 1000) {
            _recordPoint(pos);
          }
        });
      } else {
        // iOS: native CLLocationManager (no Flutter Timer, no stream)
        _iosEventSub = _iosEvents.receiveBroadcastStream().listen((data) {
          if (data is Map) {
            // Check for low power mode notification
            if (data.containsKey('_lowPowerMode')) {
              final lp = data['_lowPowerMode'] == true;
              if (mounted) setState(() => _lowPowerMode = lp);
              if (lp) {
                _showSnackBar('Low Power Mode ON — GPS accuracy reduced. Disable for best results.');
              } else {
                _showSnackBar('Low Power Mode OFF — full GPS resumed.');
              }
              return;
            }
            try {
              final pos = Position(
                latitude: (data['latitude'] as num).toDouble(),
                longitude: (data['longitude'] as num).toDouble(),
                accuracy: (data['accuracy'] as num).toDouble(),
                speed: (data['speed'] as num?)?.toDouble() ?? 0,
                altitude: (data['altitude'] as num?)?.toDouble() ?? 0,
                heading: (data['heading'] as num?)?.toDouble() ?? 0,
                timestamp: DateTime.fromMillisecondsSinceEpoch((data['timestamp'] as num).toInt()),
                altitudeAccuracy: 0,
                headingAccuracy: 0,
                speedAccuracy: 0,
              );
              _recordPoint(pos);
            } catch (e) {
              debugPrint('iOS event parse error: $e');
            }
          }
        });
        await _iosChannel.invokeMethod('start', {'intervalSeconds': _intervalSeconds});
      }

      setState(() => _isCollecting = true);
      _showSnackBar('Recording every ${_intervalSeconds}s');
    } catch (e) {
      _showSnackBar('Error: $e');
      debugPrint('Start error: $e');
    }
  }

  Future<void> _startAndroidService() async {
    final notifPerm = await FlutterForegroundTask.checkNotificationPermission();
    if (notifPerm != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'zairn_trace',
        channelName: 'Zairn Trace',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(showNotification: false),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(60000),
        autoRunOnBoot: false,
        allowWakeLock: true,
      ),
    );

    await FlutterForegroundTask.startService(
      serviceId: 256,
      notificationTitle: 'Zairn Trace',
      notificationText: 'Recording...',
      callback: startCallback,
    );
  }

  void _recordPoint(Position pos) {
    try {
      final now = DateTime.now();
      _lastRecordedTs = now.millisecondsSinceEpoch;
      final point = {
        'lat': double.parse(pos.latitude.toStringAsFixed(7)),
        'lon': double.parse(pos.longitude.toStringAsFixed(7)),
        'accuracy': pos.accuracy.round(),
        'speed': pos.speed,
        'altitude': pos.altitude,
        'timestamp': now.toIso8601String(),
        'hour': now.hour,
        'ts': now.millisecondsSinceEpoch,
      };

      _privacyProcessor ??= createPrivacyProcessor(
        config: PrivacyConfig(gridSeed: 'trace-collector'),
      );
      _lastPrivacyState = _privacyProcessor!.process(pos.latitude, pos.longitude);

      _appendPoint(point);
      if (mounted) setState(() {});

      // Update Android notification
      if (Platform.isAndroid) {
        FlutterForegroundTask.updateService(
          notificationTitle: 'Zairn Trace',
          notificationText: '$_pointCount pts | ${pos.latitude.toStringAsFixed(4)}, ${pos.longitude.toStringAsFixed(4)}',
        );
      }
    } catch (e) {
      debugPrint('Record error: $e');
    }
  }

  Future<void> _stop() async {
    _posStream?.cancel();
    _posStream = null;
    _iosEventSub?.cancel();
    _iosEventSub = null;
    if (Platform.isIOS) {
      try { await _iosChannel.invokeMethod('stop'); } catch (_) {}
    }
    if (Platform.isAndroid) {
      await FlutterForegroundTask.stopService();
    }
    if (mounted) setState(() => _isCollecting = false);
  }

  // =====================
  // Export / Clear
  // =====================

  Future<void> _export() async {
    debugPrint('Export: starting...');
    if (_traceFile == null || !await _traceFile!.exists() || _pointCount == 0) {
      _showSnackBar('No data to export');
      return;
    }

    try {
      // Simple: just copy the JSONL file as-is. No parsing, no memory pressure.
      final filename = 'dense-trace-${DateFormat('yyyy-MM-dd-HHmm').format(DateTime.now())}.jsonl';
      final dir = await getApplicationDocumentsDirectory();
      final exportFile = File('${dir.path}/$filename');

      await _traceFile!.copy(exportFile.path);
      final size = await exportFile.length();
      debugPrint('Export: copied ${exportFile.path} (${(size / 1024).toStringAsFixed(0)} KB)');

      // Android: also copy to Downloads
      if (Platform.isAndroid) {
        try {
          final dlDir = Directory('/storage/emulated/0/Download');
          if (await dlDir.exists()) {
            await _traceFile!.copy('${dlDir.path}/$filename');
          }
        } catch (e) {
          debugPrint('Export: Downloads copy failed: $e');
        }
      }

      _showSnackBar('Saved: $filename ($_pointCount pts, ${(size / 1024).toStringAsFixed(0)} KB)');
      if (Platform.isIOS) {
        _showSnackBar('Use Finder to access app files');
      }
    } catch (e, stack) {
      debugPrint('Export error: $e\n$stack');
      _showSnackBar('Export error: $e');
    }
  }

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear all data?'),
        content: Text('$_pointCount points will be deleted.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    if (_traceFile != null && await _traceFile!.exists()) {
      await _traceFile!.delete();
    }
    setState(() { _pointCount = 0; _lastPoint = null; _lastPrivacyState = null; });
  }

  Future<void> _showCrashLog() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final logFile = File('${dir.path}/zairn-crash-log.txt');
      String content = 'No crash log found.';
      if (await logFile.exists()) {
        content = await logFile.readAsString();
        if (content.length > 3000) content = '...(truncated)\n${content.substring(content.length - 3000)}';
      }
      if (!mounted) return;
      if (!context.mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Crash Log'),
          content: SingleChildScrollView(child: Text(content, style: const TextStyle(fontSize: 10, fontFamily: 'monospace'))),
          actions: [
            TextButton(onPressed: () async {
              final f = File('${dir.path}/zairn-crash-log.txt');
              if (await f.exists()) await f.delete();
              Navigator.pop(ctx);
              _showSnackBar('Log cleared');
            }, child: const Text('Clear Log')),
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
          ],
        ),
      );
    } catch (e) {
      _showSnackBar('Error reading log: $e');
    }
  }

  void _showSnackBar(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  String _formatTimestamp(dynamic ts) {
    try {
      if (ts is String) return DateFormat('HH:mm:ss').format(DateTime.parse(ts));
      if (ts is num) return DateFormat('HH:mm:ss').format(DateTime.fromMillisecondsSinceEpoch(ts.toInt()));
      return ts.toString();
    } catch (_) {
      return '?';
    }
  }

  String _stateLabel(LocationState? s) => switch (s) {
    null => '-',
    CoarseLocation(cellId: final id) => 'Coarse: $id',
    StateOnly(label: final l) => 'State: $l',
    ProximityBucket(bucket: final b) => 'Prox: $b',
    Suppressed(reason: final r) => 'Suppressed: $r',
    PreciseLocation() => 'Precise',
  };

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Zairn Trace Collector'),
        actions: [
          IconButton(icon: const Icon(Icons.bug_report), onPressed: _showCrashLog),
          IconButton(icon: const Icon(Icons.delete_outline), onPressed: _clear),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Card(
            color: _isCollecting ? t.colorScheme.primaryContainer : t.colorScheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(children: [
                Icon(_isCollecting ? Icons.my_location : Icons.location_off, size: 48,
                    color: _isCollecting ? t.colorScheme.primary : t.colorScheme.outline),
                const SizedBox(height: 8),
                Text(_isCollecting ? (_lowPowerMode ? 'Recording (low power)' : 'Recording') : 'Stopped', style: t.textTheme.titleLarge),
                const SizedBox(height: 4),
                Text('$_pointCount points', style: t.textTheme.bodyMedium),
              ]),
            ),
          ),
          const SizedBox(height: 12),
          Row(children: [
            const Text('Interval: '),
            for (final s in [30, 60, 300]) ...[
              ChoiceChip(
                label: Text(s < 60 ? '${s}s' : '${s ~/ 60}m'),
                selected: _intervalSeconds == s,
                onSelected: _isCollecting ? null : (_) => setState(() => _intervalSeconds = s),
              ),
              const SizedBox(width: 6),
            ],
          ]),
          const SizedBox(height: 12),
          if (_lastPoint != null)
            Card(child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Last: ${_lastPoint!['lat']}, ${_lastPoint!['lon']} (${_lastPoint!['accuracy']}m)', style: t.textTheme.bodySmall),
                Text('Privacy: ${_stateLabel(_lastPrivacyState)}', style: t.textTheme.bodySmall),
                if (_lastPoint!['timestamp'] != null)
                  Text('Time: ${_formatTimestamp(_lastPoint!['timestamp'])}', style: t.textTheme.bodySmall),
              ]),
            )),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: FilledButton.icon(onPressed: _isCollecting ? null : _start, icon: const Icon(Icons.play_arrow), label: const Text('Start'))),
            const SizedBox(width: 8),
            Expanded(child: OutlinedButton.icon(onPressed: _isCollecting ? _stop : null, icon: const Icon(Icons.stop), label: const Text('Stop'))),
            const SizedBox(width: 8),
            Expanded(child: FilledButton.tonalIcon(onPressed: _pointCount == 0 ? null : _export, icon: const Icon(Icons.download), label: const Text('Export'))),
          ]),
        ]),
      ),
    );
  }
}
