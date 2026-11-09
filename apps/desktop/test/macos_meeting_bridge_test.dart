import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/features/meetings/macos_meeting_bridge.dart';

void main() {
  test('a prompt is debounced across a short interruption', () {
    final detector = MacCallDetection();
    const app = MacCallApp('us.zoom.xos', 'Zoom', browser: false);
    List<MacCallApp> observe(int seconds, [bool active = true]) =>
        detector.observe(active ? [app] : [], Duration(seconds: seconds));

    expect(observe(0), isEmpty);
    expect(observe(3), [app]);
    detector.prompted(app.id);
    expect(observe(6), isEmpty);
    expect(observe(9, false), isEmpty);
    expect(observe(12), isEmpty);
    expect(observe(15), isEmpty);
    expect(observe(36, false), isEmpty);
    expect(observe(39), isEmpty);
    expect(observe(42), [app]);
  });

  test('nearby calendar occurrences keep provider and time boundaries', () {
    const zoom = MacCallApp('us.zoom.xos', 'Zoom', browser: false);
    const chrome = MacCallApp('com.google.chrome', 'Chrome', browser: true);
    const start = 1794240000000;
    const end = start + 1800000;
    final event = MacCalendarMeeting(
      'id',
      'Project review',
      start,
      end,
      Uri.parse('https://example.zoomgov.com/j/123'),
    );
    expect(zoom.matches(event), isTrue);
    expect(chrome.matches(event), isTrue);
    expect(event.isNear(start - 300001), isFalse);
    expect(event.isNear(start - 300000), isTrue);
    expect(event.isNear(end), isFalse);
  });
}
