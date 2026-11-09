part of 'meetings_controller.dart';

extension _MacMeetingViews on MeetingsController {
  static const _pollInterval = Duration(seconds: 3);
  MacOSMeetingBridge get _macMeetings => _host.environment.macOSMeetings!;

  void _startMacMeetingWatch() {
    if (_host.environment.macOSMeetings == null) return;
    _macMeetingTimer = Timer.periodic(
      _pollInterval,
      (timer) => unawaited(_pollMacMeetings(_pollInterval * timer.tick)),
    );
  }

  Future<void> _refreshMacCalendar({bool prompt = false}) async {
    var access = await _macMeetings.calendarAccess();
    if (prompt && (access == 'notDetermined' || access == 'writeOnly')) {
      if (await _macMeetings.requestCalendarAccess()) access = 'fullAccess';
    }
    final events = access == 'fullAccess'
        ? await _macMeetings.upcomingMeetings()
        : const <MacCalendarMeeting>[];
    if (!mounted) return;
    _macCalendarRefreshed = DateTime.now();
    update(() => _macUpcoming = events);
  }

  Future<void> _pollMacMeetings(Duration elapsed) async {
    if (!mounted || _macPollBusy || _callPromptsReady?.call() == false) return;
    final dialogContext = context;
    _macPollBusy = true;
    try {
      final now = DateTime.now();
      final refreshed = _macCalendarRefreshed;
      if (!_macDialogOpen &&
          (refreshed == null || now.difference(refreshed).inSeconds >= 45)) {
        try {
          await _refreshMacCalendar();
        } on PlatformException {
          if (mounted) update(() => _macUpcoming = const []);
          _macCalendarRefreshed = now;
        }
      }
      if (!mounted) return;
      final apps = await _macMeetings.activeCallApps();
      if (!mounted || !dialogContext.mounted) return;
      final possible = _macCallDetection.observe(apps, elapsed);
      if (_macDialogOpen ||
          _operations.busy ||
          quickStarting ||
          recording != null ||
          recordingMeeting != null ||
          ModalRoute.of(dialogContext)?.isCurrent == false) {
        return;
      }
      final nearby = _macUpcoming
          .where((event) => event.isNear(now.millisecondsSinceEpoch))
          .toList();
      final ordered = [
        ...possible.where((app) => !app.browser),
        ...possible.where((app) => app.browser),
      ];
      for (final app in ordered) {
        final matches = nearby.where(app.matches).toList();
        // Browser input alone can also be dictation. Require a nearby event
        // or simultaneous playback before suggesting a possible browser call.
        if (app.browser && matches.isEmpty && !app.outputActive) continue;
        await _showDetectedCall(app, matches);
        break;
      }
    } on MissingPluginException {
      // Unsupported hosts and alternate runners have no native bridge.
      _macMeetingTimer?.cancel();
    } on PlatformException {
      // A failed HAL read is not a call ending. Recheck on the next poll.
    } finally {
      _macPollBusy = false;
    }
  }

  Widget _macCalendarButton() => OutlinedButton.icon(
    onPressed: _operations.busy || _macDialogOpen
        ? null
        : () => unawaited(_showMacCalendar()),
    icon: const Icon(Icons.calendar_today, size: 18),
    label: Text(
      _macUpcoming.isEmpty
          ? 'Mac Calendar'
          : 'Mac Calendar (${_macUpcoming.length})',
    ),
  );

  Future<void> _showMacCalendar() async {
    if (_macDialogOpen) return;
    _macDialogOpen = true;
    try {
      final identity = FeatureRequestIdentity.capture(d);
      bool current() => identity.isCurrent(d, alive: mounted);
      await _refreshMacCalendar(prompt: true);
      final access = await _macMeetings.calendarAccess();
      if (!current()) return;
      final events = List<MacCalendarMeeting>.of(_macUpcoming);
      final event = await _dialogs.showInputDialog<MacCalendarMeeting>(
        builder: (context) => SimpleDialog(
          title: const Text('Upcoming from Mac Calendar'),
          children: [
            if (access != 'fullAccess')
              const Padding(
                padding: EdgeInsets.fromLTRB(24, 0, 24, 12),
                child: Text(
                  'Allow Calendar access for Open Foresight in System Settings '
                  'to see events already on this Mac.',
                ),
              )
            else if (events.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(24, 0, 24, 12),
                child: Text('No timed events in the next seven days.'),
              ),
            for (final meeting in events)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, meeting),
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(meeting.title),
                  subtitle: Text(
                    '${meetingDay(meeting.starts)} · ${meetingClock(meeting.starts)}',
                  ),
                ),
              ),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      );
      if (event != null && current()) {
        await _openMacMeeting(event, current: current);
      }
    } catch (failure) {
      if (mounted) _operations.reportAsyncError(failure);
    } finally {
      _macDialogOpen = false;
      if (mounted) update(() {});
    }
  }

  Future<void> _showDetectedCall(
    MacCallApp app,
    List<MacCalendarMeeting> matches,
  ) async {
    final identity = FeatureRequestIdentity.capture(d);
    bool current() => identity.isCurrent(d, alive: mounted);
    _macDialogOpen = true;
    _macCallDetection.prompted(app.id);
    try {
      _macMeetings.requestCallAttention().ignore();
      var chosen = matches.length == 1 ? matches.single.id : '';
      final decision = await _dialogs.showInputDialog<bool>(
        builder: (context) => StatefulBuilder(
          builder: (context, setState) => AlertDialog(
            title: const Text('Possible call detected'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${app.name} is using the microphone.'),
                const Text('Choose a meeting to open or start recording.'),
                if (matches.isNotEmpty)
                  DropdownButton<String>(
                    isExpanded: true,
                    value: chosen,
                    items: [
                      const DropdownMenuItem(
                        value: '',
                        child: Text('New meeting'),
                      ),
                      for (final meeting in matches)
                        DropdownMenuItem(
                          value: meeting.id,
                          child: Text(
                            meeting.title,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (value) => setState(() => chosen = value ?? ''),
                  ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Dismiss'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Open meeting'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Start recording'),
              ),
            ],
          ),
        ),
      );
      if (decision == null || !current()) return;
      final event = matches
          .where((meeting) => meeting.id == chosen)
          .firstOrNull;
      final id = await _openMacMeeting(event, current: current);
      if (decision && id != null && current() && meetingId == id) {
        await recordExistingMeeting(
          id,
          confirmedCallIsActive: () async =>
              (await _macMeetings.activeCallApps()).any(
                (candidate) => candidate.id == app.id,
              ),
        );
      }
    } catch (failure) {
      if (current()) _operations.reportAsyncError(failure);
    } finally {
      _macDialogOpen = false;
    }
  }

  Future<int?> _openMacMeeting(
    MacCalendarMeeting? event, {
    required bool Function() current,
  }) async {
    int? id;
    if (!current() || _operations.busy || recording != null) return null;
    final identity = FeatureRequestIdentity.capture(d);
    await _operations.run(() async {
      await flushMeetingNotesDraft();
      if (!current()) return;
      final meeting = await meetingsCreateDescriptor.sendCurrent(
        d,
        MeetingsCreateInput(
          title: event?.title ?? '[New Meeting]',
          calendarEventId: event?.id,
          starts: event?.starts,
          ends: event?.ends,
          envelope: ClientEnvelope(
            workspaceEpoch: WireField(identity.workspaceEpoch),
          ),
        ),
        current,
      );
      if (!current()) return;
      id = meeting.id;
      update(() {
        _navigation.navigate(WorkspaceTab.meetings);
        meetingPreviewId = null;
        meetingId = meeting.id;
      });
    });
    return id;
  }
}
