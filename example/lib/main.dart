import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zairn_sdk/zairn_sdk.dart';

// ============================================================
// Android: Foreground task handler (runs as foreground service)
// ============================================================

@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(LocationTaskHandler());
}

class LocationTaskHandler extends TaskHandler {
  StreamSubscription<Position>? _posStream;
  Position? _lastPos;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    _posStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 0,
      ),
    ).listen((pos) => _lastPos = pos);
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    final pos = _lastPos;
    if (pos == null) return;
    final now = DateTime.now();
    FlutterForegroundTask.sendDataToMain({
      'lat': double.parse(pos.latitude.toStringAsFixed(7)),
      'lon': double.parse(pos.longitude.toStringAsFixed(7)),
      'accuracy': pos.accuracy.round(),
      'speed': pos.speed,
      'altitude': pos.altitude,
      'timestamp': now.toIso8601String(),
      'hour': now.hour,
      'ts': now.millisecondsSinceEpoch,
    });
    FlutterForegroundTask.updateService(
      notificationTitle: 'Zairn Trace',
      notificationText: '${pos.latitude.toStringAsFixed(4)}, ${pos.longitude.toStringAsFixed(4)}',
    );
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    _posStream?.cancel();
  }
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
  static const _storageKey = 'dense_trace_data';

  bool _isCollecting = false;
  List<Map<String, dynamic>> _trace = [];
  int _intervalSeconds = 60;

  // iOS: direct stream + timer
  StreamSubscription<Position>? _iosPosStream;
  Timer? _iosTimer;
  Position? _iosLastPos;

  PrivacyProcessor? _privacyProcessor;
  LocationState? _lastPrivacyState;

  bool get _isAndroid => Platform.isAndroid;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadTrace();
    if (_isAndroid) {
      _initAndroidForegroundTask();
      FlutterForegroundTask.addTaskDataCallback(_onDataFromTask);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopIos();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Reload data when coming back to foreground
      _loadTrace();
    }
  }

  // =====================
  // Android foreground service setup
  // =====================

  void _initAndroidForegroundTask() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'zairn_trace',
        channelName: 'Zairn Trace Collector',
        channelDescription: 'GPS trace collection',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(showNotification: false, playSound: false),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(_intervalSeconds * 1000),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: false,
      ),
    );
  }

  void _onDataFromTask(Object data) {
    if (data is Map<String, dynamic>) {
      _addPoint(data);
    }
  }

  // =====================
  // Data handling
  // =====================

  void _addPoint(Map<String, dynamic> point) {
    try {
      _privacyProcessor ??= createPrivacyProcessor(
        config: PrivacyConfig(gridSeed: 'trace-collector'),
      );
      final lat = (point['lat'] as num).toDouble();
      final lon = (point['lon'] as num).toDouble();
      _lastPrivacyState = _privacyProcessor!.process(lat, lon);
      _trace.add(point);
      _saveTrace();
      if (mounted) setState(() {});
    } catch (_) {
      // Silently ignore errors during background/foreground transitions
    }
  }

  Future<void> _loadTrace() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_storageKey);
    if (json != null) {
      setState(() {
        _trace = List<Map<String, dynamic>>.from(jsonDecode(json) as List);
      });
    }
  }

  Future<void> _saveTrace() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_storageKey, jsonEncode(_trace));
  }

  // =====================
  // Start / Stop
  // =====================

  Future<void> _start() async {
    if (_isCollecting) return;

    if (!await Geolocator.isLocationServiceEnabled()) {
      _showSnackBar('Location services disabled. Enable GPS.');
      return;
    }

    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied) {
        _showSnackBar('Location permission denied');
        return;
      }
    }
    if (perm == LocationPermission.deniedForever) {
      _showSnackBar('Permission denied. Opening settings...');
      await Geolocator.openAppSettings();
      return;
    }

    if (_isAndroid) {
      await _startAndroid();
    } else {
      await _startIos();
    }
  }

  Future<void> _startAndroid() async {
    final notifPerm = await FlutterForegroundTask.checkNotificationPermission();
    if (notifPerm != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }

    _initAndroidForegroundTask();

    final result = await FlutterForegroundTask.startService(
      serviceId: 256,
      notificationTitle: 'Zairn Trace',
      notificationText: 'Recording every ${_intervalSeconds}s...',
      callback: startCallback,
    );

    if (result is ServiceRequestSuccess) {
      setState(() => _isCollecting = true);
      _showSnackBar('Recording (background service)');
    } else {
      _showSnackBar('Failed to start service');
    }
  }

  Future<void> _startIos() async {
    // iOS: use Geolocator stream with background mode enabled via Info.plist
    _iosPosStream = Geolocator.getPositionStream(
      locationSettings: AppleSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 0,
        activityType: ActivityType.other,
        pauseLocationUpdatesAutomatically: false,
        showBackgroundLocationIndicator: true,
        allowBackgroundLocationUpdates: true,
      ),
    ).listen((pos) => _iosLastPos = pos);

    // Record at fixed interval
    _recordIosPoint();
    _iosTimer = Timer.periodic(Duration(seconds: _intervalSeconds), (_) => _recordIosPoint());

    setState(() => _isCollecting = true);
    _showSnackBar('Recording (iOS background, every ${_intervalSeconds}s)');
  }

  void _recordIosPoint() {
    try {
      final pos = _iosLastPos;
      if (pos == null) return;
      final now = DateTime.now();
      _addPoint({
      'lat': double.parse(pos.latitude.toStringAsFixed(7)),
      'lon': double.parse(pos.longitude.toStringAsFixed(7)),
      'accuracy': pos.accuracy.round(),
      'speed': pos.speed,
      'altitude': pos.altitude,
      'timestamp': now.toIso8601String(),
      'hour': now.hour,
      'ts': now.millisecondsSinceEpoch,
    });
    } catch (_) {}
  }

  Future<void> _stop() async {
    if (_isAndroid) {
      await FlutterForegroundTask.stopService();
    } else {
      _stopIos();
    }
    setState(() => _isCollecting = false);
  }

  void _stopIos() {
    _iosPosStream?.cancel();
    _iosPosStream = null;
    _iosTimer?.cancel();
    _iosTimer = null;
  }

  // =====================
  // Export / Clear
  // =====================

  Future<void> _export() async {
    if (_trace.isEmpty) { _showSnackBar('No data'); return; }
    final meta = {
      'device': '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      'points': _trace.length,
      'startTime': _trace.first['timestamp'],
      'endTime': _trace.last['timestamp'],
      'durationHours': ((_trace.last['ts'] - _trace.first['ts']) / 3600000).toStringAsFixed(1),
      'intervalSeconds': _intervalSeconds,
    };
    final data = jsonEncode({'meta': meta, 'trace': _trace});
    final filename = 'dense-trace-${DateFormat('yyyy-MM-dd').format(DateTime.now())}.json';

    try {
      if (Platform.isAndroid) {
        final dir = Directory('/storage/emulated/0/Download');
        if (await dir.exists()) {
          await File('${dir.path}/$filename').writeAsString(data);
          _showSnackBar('Saved: Downloads/$filename');
          return;
        }
      }
      // Fallback: show size info
      _showSnackBar('${_trace.length} points, ${(data.length / 1024).toStringAsFixed(0)} KB. Use share/airdrop to transfer.');
    } catch (e) {
      _showSnackBar('Export error: $e');
    }
  }

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear all data?'),
        content: Text('${_trace.length} points will be deleted.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_storageKey);
    setState(() { _trace = []; _lastPrivacyState = null; });
  }

  void _showSnackBar(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  String _dur() {
    if (_trace.length < 2) return '0h';
    final ms = _trace.last['ts'] - _trace.first['ts'];
    return ms < 3600000 ? '${(ms / 60000).round()}m' : '${(ms / 3600000).toStringAsFixed(1)}h';
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
        actions: [IconButton(icon: const Icon(Icons.delete_outline), onPressed: _trace.isEmpty ? null : _clear)],
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
                Text(_isCollecting ? 'Recording${_isAndroid ? " (service)" : " (iOS bg)"}' : 'Stopped', style: t.textTheme.titleLarge),
                const SizedBox(height: 4),
                Text('${_trace.length} points | ${_dur()}', style: t.textTheme.bodyMedium),
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
          if (_trace.isNotEmpty)
            Card(child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Last: ${_trace.last['lat']}, ${_trace.last['lon']} (${_trace.last['accuracy']}m)', style: t.textTheme.bodySmall),
                Text('Privacy: ${_stateLabel(_lastPrivacyState)}', style: t.textTheme.bodySmall),
              ]),
            )),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: FilledButton.icon(onPressed: _isCollecting ? null : _start, icon: const Icon(Icons.play_arrow), label: const Text('Start'))),
            const SizedBox(width: 8),
            Expanded(child: OutlinedButton.icon(onPressed: _isCollecting ? _stop : null, icon: const Icon(Icons.stop), label: const Text('Stop'))),
            const SizedBox(width: 8),
            Expanded(child: FilledButton.tonalIcon(onPressed: _trace.isEmpty ? null : _export, icon: const Icon(Icons.download), label: const Text('Export'))),
          ]),
          const SizedBox(height: 12),
          Text('Recent', style: t.textTheme.titleSmall),
          Expanded(
            child: _trace.isEmpty
                ? Center(child: Text('Tap Start to begin.', style: t.textTheme.bodyLarge?.copyWith(color: t.colorScheme.outline)))
                : ListView.builder(
                    reverse: true, itemCount: _trace.length,
                    itemBuilder: (_, i) {
                      final p = _trace[_trace.length - 1 - i];
                      return ListTile(
                        dense: true,
                        leading: Text('#${_trace.length - i}', style: t.textTheme.bodySmall),
                        title: Text('${p['lat']}, ${p['lon']}'),
                        subtitle: Text('${DateFormat('HH:mm:ss').format(DateTime.parse(p['timestamp'] as String))} | ${p['accuracy']}m'),
                      );
                    }),
          ),
        ]),
      ),
    );
  }
}
