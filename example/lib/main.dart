import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zairn_sdk/zairn_sdk.dart';

void main() {
  runApp(const ZairnExampleApp());
}

class ZairnExampleApp extends StatelessWidget {
  const ZairnExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Zairn Trace Collector',
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF6442D6),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: const Color(0xFF6442D6),
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const TraceCollectorPage(),
    );
  }
}

/// Dense location trace collector for IMWUT evaluation.
///
/// Records GPS position at regular intervals, stores locally,
/// and exports as JSON for analysis.
class TraceCollectorPage extends StatefulWidget {
  const TraceCollectorPage({super.key});

  @override
  State<TraceCollectorPage> createState() => _TraceCollectorPageState();
}

class _TraceCollectorPageState extends State<TraceCollectorPage> {
  static const _storageKey = 'dense_trace_data';

  bool _isCollecting = false;
  StreamSubscription<Position>? _positionSubscription;
  Timer? _timer;
  Position? _lastPosition;
  List<Map<String, dynamic>> _trace = [];
  int _intervalSeconds = 60;

  // Privacy demo
  PrivacyProcessor? _privacyProcessor;
  LocationState? _lastPrivacyState;

  @override
  void initState() {
    super.initState();
    _loadTrace();
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
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

  Future<void> _start() async {
    if (_isCollecting) return;

    // Check permissions
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      _showSnackBar('Location services are disabled. Please enable GPS.');
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        _showSnackBar('Location permission denied');
        return;
      }
    }
    if (permission == LocationPermission.deniedForever) {
      _showSnackBar('Location permission permanently denied.');
      await Geolocator.openAppSettings();
      return;
    }

    // Request "Always" permission for background collection
    if (permission == LocationPermission.whileInUse) {
      _showSnackBar('Background location needed. Please select "Allow all the time" in the next dialog.');
      // On Android, this opens the app settings where user can change to "Always"
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.whileInUse) {
        // Still only "while in use" — open settings manually
        await Geolocator.openAppSettings();
        _showSnackBar('Please select "Allow all the time" in app settings, then tap Start again.');
        return;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      _showSnackBar('Location permission permanently denied. Enable in settings.');
      return;
    }

    // Initialize privacy processor for demo
    _privacyProcessor = createPrivacyProcessor(
      config: PrivacyConfig(gridSeed: 'demo-user-${DateTime.now().millisecondsSinceEpoch}'),
    );

    setState(() => _isCollecting = true);

    // Start watching position
    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 0,
      ),
    ).listen((position) {
      _lastPosition = position;
    });

    // Record at fixed interval
    _recordPoint();
    _timer = Timer.periodic(Duration(seconds: _intervalSeconds), (_) => _recordPoint());

    _showSnackBar('Started collecting (every ${_intervalSeconds}s)');
  }

  void _stop() {
    _positionSubscription?.cancel();
    _positionSubscription = null;
    _timer?.cancel();
    _timer = null;
    setState(() => _isCollecting = false);
  }

  void _recordPoint() {
    final pos = _lastPosition;
    if (pos == null) return;

    final now = DateTime.now();
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

    // Run through privacy processor for demo
    if (_privacyProcessor != null) {
      _lastPrivacyState = _privacyProcessor!.process(pos.latitude, pos.longitude);
    }

    setState(() {
      _trace.add(point);
    });
    _saveTrace();
  }

  Future<void> _export() async {
    if (_trace.isEmpty) {
      _showSnackBar('No data to export');
      return;
    }

    final meta = {
      'device': Platform.operatingSystem,
      'points': _trace.length,
      'startTime': _trace.first['timestamp'],
      'endTime': _trace.last['timestamp'],
      'durationHours': ((_trace.last['ts'] - _trace.first['ts']) / 3600000).toStringAsFixed(1),
      'intervalSeconds': _intervalSeconds,
    };

    final data = jsonEncode({'meta': meta, 'trace': _trace});
    final dateStr = DateFormat('yyyy-MM-dd').format(DateTime.now());
    final filename = 'dense-trace-$dateStr.json';

    // Save to downloads or share
    // For simplicity, copy to clipboard description
    _showSnackBar('${_trace.length} points ready. File: $filename (${(data.length / 1024).toStringAsFixed(1)} KB)');

    // Write to app documents directory
    final dir = Directory('/storage/emulated/0/Download');
    if (await dir.exists()) {
      final file = File('${dir.path}/$filename');
      await file.writeAsString(data);
      _showSnackBar('Saved to Downloads/$filename');
    }
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
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
    if (confirmed != true) return;

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_storageKey);
    setState(() {
      _trace = [];
      _lastPrivacyState = null;
    });
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  String _formatDuration() {
    if (_trace.length < 2) return '0h';
    final ms = _trace.last['ts'] - _trace.first['ts'];
    final hours = ms / 3600000;
    if (hours < 1) return '${(ms / 60000).round()}m';
    return '${hours.toStringAsFixed(1)}h';
  }

  String _privacyStateLabel(LocationState? state) {
    if (state == null) return '-';
    return switch (state) {
      CoarseLocation(cellId: final id) => 'Coarse: $id',
      StateOnly(label: final l) => 'State: $l',
      ProximityBucket(bucket: final b) => 'Proximity: $b',
      Suppressed(reason: final r) => 'Suppressed: $r',
      PreciseLocation() => 'Precise',
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Zairn Trace Collector'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: _trace.isEmpty ? null : _clear,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Status card
            Card(
              color: _isCollecting
                  ? theme.colorScheme.primaryContainer
                  : theme.colorScheme.surfaceContainerHighest,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Icon(
                      _isCollecting ? Icons.my_location : Icons.location_off,
                      size: 48,
                      color: _isCollecting
                          ? theme.colorScheme.primary
                          : theme.colorScheme.outline,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _isCollecting ? 'Collecting...' : 'Stopped',
                      style: theme.textTheme.titleLarge,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${_trace.length} points | ${_formatDuration()} | '
                      '${(_trace.length * 50 / 1024).toStringAsFixed(1)} KB',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),

            // Interval selector
            Row(
              children: [
                const Text('Interval: '),
                ChoiceChip(
                  label: const Text('30s'),
                  selected: _intervalSeconds == 30,
                  onSelected: _isCollecting ? null : (_) => setState(() => _intervalSeconds = 30),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('1m'),
                  selected: _intervalSeconds == 60,
                  onSelected: _isCollecting ? null : (_) => setState(() => _intervalSeconds = 60),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('5m'),
                  selected: _intervalSeconds == 300,
                  onSelected: _isCollecting ? null : (_) => setState(() => _intervalSeconds = 300),
                ),
              ],
            ),

            const SizedBox(height: 16),

            // Privacy state demo
            if (_lastPosition != null) ...[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Last GPS', style: theme.textTheme.labelLarge),
                      Text(
                        '${_lastPosition!.latitude.toStringAsFixed(6)}, '
                        '${_lastPosition!.longitude.toStringAsFixed(6)} '
                        '(${_lastPosition!.accuracy.round()}m)',
                      ),
                      const SizedBox(height: 4),
                      Text('Privacy output', style: theme.textTheme.labelLarge),
                      Text(_privacyStateLabel(_lastPrivacyState)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Buttons
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _isCollecting ? null : _start,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Start'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _isCollecting ? _stop : null,
                    icon: const Icon(Icons.stop),
                    label: const Text('Stop'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: _trace.isEmpty ? null : _export,
                    icon: const Icon(Icons.download),
                    label: const Text('Export'),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 16),

            // Recent points
            Text('Recent points', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Expanded(
              child: _trace.isEmpty
                  ? Center(
                      child: Text(
                        'No data yet. Tap Start to begin collecting.',
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                    )
                  : ListView.builder(
                      reverse: true,
                      itemCount: _trace.length,
                      itemBuilder: (ctx, i) {
                        final idx = _trace.length - 1 - i;
                        final p = _trace[idx];
                        final time = DateFormat('HH:mm:ss').format(
                          DateTime.parse(p['timestamp'] as String),
                        );
                        return ListTile(
                          dense: true,
                          leading: Text('#${idx + 1}', style: theme.textTheme.bodySmall),
                          title: Text(
                            '${p['lat']}, ${p['lon']}',
                            style: theme.textTheme.bodyMedium,
                          ),
                          subtitle: Text('$time | ${p['accuracy']}m'),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
