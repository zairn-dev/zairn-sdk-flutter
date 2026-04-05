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
    if (state == AppLifecycleState.resumed) {
      // Reload point count from file after a safe delay
      Future.delayed(const Duration(seconds: 1), () {
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
      // Count lines without loading entire file
      final stream = _traceFile!.openRead();
      int count = 0;
      await for (final chunk in stream.transform(utf8.decoder).transform(const LineSplitter())) {
        if (chunk.trim().isNotEmpty) count++;
      }
      if (mounted) {
        setState(() => _pointCount = count);
      }
    } catch (e) {
      debugPrint('Reload error: $e');
    }
  }

  Future<void> _initTraceFile() async {
    final dir = await getApplicationDocumentsDirectory();
    _traceFile = File('${dir.path}/dense-trace.jsonl');
    if (await _traceFile!.exists()) {
      final lines = await _traceFile!.readAsLines();
      _pointCount = lines.length;
      if (lines.isNotEmpty) {
        try { _lastPoint = jsonDecode(lines.last) as Map<String, dynamic>; } catch (_) {}
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _appendPoint(Map<String, dynamic> point) async {
    if (_traceFile == null) return;
    await _traceFile!.writeAsString('${jsonEncode(point)}\n', mode: FileMode.append);
    _pointCount++;
    _lastPoint = point;
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
      final filename = 'dense-trace-${DateFormat('yyyy-MM-dd-HHmm').format(DateTime.now())}.json';
      final dir = await getApplicationDocumentsDirectory();
      final exportFile = File('${dir.path}/$filename');

      // Stream-write: never load entire trace into memory
      final sink = exportFile.openWrite();
      final source = _traceFile!.openRead();
      final lines = source.transform(utf8.decoder).transform(const LineSplitter());

      String? firstTs;
      String? lastTs;
      int count = 0;

      // Write opening
      sink.write('{"meta":');

      // Buffer trace entries, write in chunks
      final traceBuffer = StringBuffer();
      traceBuffer.write('[');
      bool first = true;

      await for (final line in lines) {
        if (line.trim().isEmpty) continue;
        try {
          // Validate it's valid JSON
          final parsed = jsonDecode(line);
          if (!first) traceBuffer.write(',');
          traceBuffer.write(line);
          first = false;
          count++;

          // Track first/last timestamp
          final ts = parsed['timestamp']?.toString();
          firstTs ??= ts;
          lastTs = ts;

          // Flush buffer every 500 entries to limit memory
          if (count % 500 == 0) {
            sink.write(traceBuffer.toString());
            traceBuffer.clear();
            debugPrint('Export: $count points written...');
          }
        } catch (_) {}
      }

      traceBuffer.write(']');

      // Write meta + remaining trace
      final meta = jsonEncode({
        'device': '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
        'points': count,
        'startTime': firstTs,
        'endTime': lastTs,
        'intervalSeconds': _intervalSeconds,
      });
      sink.write(meta);
      sink.write(',"trace":');
      sink.write(traceBuffer.toString());
      sink.write('}');
      await sink.flush();
      await sink.close();

      final size = await exportFile.length();
      debugPrint('Export: $filename ($count pts, ${(size / 1024).toStringAsFixed(0)} KB)');

      // Android: also copy to Downloads
      if (Platform.isAndroid) {
        try {
          final dlDir = Directory('/storage/emulated/0/Download');
          if (await dlDir.exists()) {
            await exportFile.copy('${dlDir.path}/$filename');
          }
        } catch (e) {
          debugPrint('Export: Downloads copy failed: $e');
        }
      }

      _showSnackBar('Saved: $filename ($count pts, ${(size / 1024).toStringAsFixed(0)} KB)');
      if (Platform.isIOS) {
        _showSnackBar('Connect iPhone to Finder to access files');
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
        actions: [IconButton(icon: const Icon(Icons.delete_outline), onPressed: _clear)],
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
                Text(_isCollecting ? 'Recording' : 'Stopped', style: t.textTheme.titleLarge),
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
