import 'package:flutter/services.dart';

final class MacCalendarMeeting {
  const MacCalendarMeeting(
    this.id,
    this.title,
    this.starts,
    this.ends,
    this.url,
  );

  final String id, title;
  final int starts, ends;
  final Uri? url;

  bool isNear(int now) =>
      starts <= now + const Duration(minutes: 5).inMilliseconds && now < ends;
}

final class MacCallApp {
  const MacCallApp(
    this.id,
    this.name, {
    required this.browser,
    this.outputActive = false,
  });

  final String id, name;
  final bool browser, outputActive;

  bool matches(MacCalendarMeeting event) {
    final host = event.url?.host.toLowerCase() ?? '';
    if (host.isEmpty) return false;
    if (browser) return true;
    if (id.contains('zoom'))
      return host == 'zoom.us' ||
          host.endsWith('.zoom.us') ||
          host == 'zoomgov.com' ||
          host.endsWith('.zoomgov.com');
    if (id.contains('teams')) return host.startsWith('teams.');
    if (id.contains('webex'))
      return host == 'webex.com' || host.endsWith('.webex.com');
    return false;
  }
}

/// Two observations confirm a possible call. A short input interruption
/// (mute or a device switch) does not reopen a dismissed prompt.
final class MacCallDetection {
  final _firstSeen = <String, Duration>{};
  final _lastSeen = <String, Duration>{};
  final _prompted = <String>{};

  List<MacCallApp> observe(List<MacCallApp> apps, Duration elapsed) {
    final ids = apps.map((app) => app.id).toSet();
    _firstSeen.removeWhere((id, _) => !ids.contains(id));
    _lastSeen.removeWhere((id, seen) {
      if (ids.contains(id) || elapsed - seen < const Duration(seconds: 20)) {
        return false;
      }
      _prompted.remove(id);
      return true;
    });
    return [
      for (final app in apps)
        if (_stable(app.id, elapsed) && !_prompted.contains(app.id)) app,
    ];
  }

  bool _stable(String id, Duration elapsed) {
    _lastSeen[id] = elapsed;
    final first = _firstSeen.putIfAbsent(id, () => elapsed);
    return elapsed - first >= const Duration(seconds: 3);
  }

  void prompted(String id) => _prompted.add(id);
}

final class MacOSMeetingBridge {
  const MacOSMeetingBridge();
  static const _channel = MethodChannel('open_foresight/macos_meetings');

  Future<String> calendarAccess() async =>
      await _channel.invokeMethod<String>('calendarAccess') ?? 'unavailable';

  Future<bool> requestCalendarAccess() async =>
      await _channel.invokeMethod<bool>('requestCalendarAccess') ?? false;

  Future<List<MacCalendarMeeting>> upcomingMeetings() async {
    final rows = await _channel.invokeListMethod<Map>('upcomingMeetings') ?? [];
    return [
      for (final row in rows)
        MacCalendarMeeting(
          row['id'] as String,
          row['title'] as String,
          row['startMs'] as int,
          row['endMs'] as int,
          Uri.tryParse(row['joinUrl'] as String? ?? ''),
        ),
    ];
  }

  Future<List<MacCallApp>> activeCallApps() async {
    final rows = await _channel.invokeListMethod<Map>('activeCallApps') ?? [];
    return [
      for (final row in rows)
        MacCallApp(
          row['id'] as String,
          row['name'] as String,
          browser: row['kind'] == 'browser',
          outputActive: row['outputActive'] == true,
        ),
    ];
  }

  Future<void> requestCallAttention() =>
      _channel.invokeMethod<void>('requestCallAttention');
}
