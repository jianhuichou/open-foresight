import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/desktop.dart'
    show MeetingLocalAttachment, Operation;

import '../test_support/core_fixture.dart' as core show State;
import 'controller_fixture.dart';
import 'desktop_fixture_owner.dart';
import 'pump_until.dart';

void main() {
  testWidgets(
    'paperclip attaches Finder files and folders to the open meeting',
    (tester) async => withDesktopFixtures(tester, () async {
      final f = await ControllerFixture.mount(tester);
      f.connection.application.domain.helper.snapshot = core.State(
        pipeline: 'unconfigured',
      );
      final meeting = f.store.meeting('Attachment pilot');
      final unrelated = f.store.meeting('Unrelated');
      final folder = Directory('${f.root.path}/Meeting references')
        ..createSync();
      final first = File('${folder.path}/Agenda.md')
        ..writeAsStringSync('# Agenda');
      final standalone = File('${f.root.path}/Project.txt')
        ..writeAsStringSync('Project brief');
      final messenger = tester.binding.defaultBinaryMessenger;
      const picker = MethodChannel('plugins.flutter.io/file_selector');
      messenger.setMockMethodCallHandler(picker, (call) async {
        return switch (call.method) {
          'getDirectoryPath' => folder.path,
          'openFile' => [standalone.path],
          _ => throw StateError('Unexpected picker command ${call.method}'),
        };
      });
      addTearDown(() => messenger.setMockMethodCallHandler(picker, null));
      f.shell.update(() => f.shell.meetingFeature.meetingId = meeting);
      await tester.pumpAndSettle();

      List<MeetingLocalAttachment> saved(int id) =>
          MeetingLocalAttachment.decodeList(
            f.store.preference(MeetingLocalAttachment.preferenceKey(id), '[]'),
          );
      Future<void> choose(String label) async {
        await pumpUntil(tester, () => !f.shell.busy);
        await tester.tap(
          find.byTooltip('Attach files or a folder to this meeting'),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(label));
      }

      await choose('Attach files…');
      await pumpUntil(
        tester,
        () => saved(meeting).length == 1 || f.shell.error.isNotEmpty,
      );
      expect(f.shell.error, isEmpty);
      expect(saved(meeting).single.path, standalone.resolveSymbolicLinksSync());

      await choose('Attach folder…');
      await pumpUntil(tester, () => saved(meeting).length == 2);
      final attachedFolder = saved(
        meeting,
      ).singleWhere((item) => item.isFolder);
      expect(attachedFolder.path, folder.resolveSymbolicLinksSync());
      expect(attachedFolder.sourceIds, hasLength(1));
      expect(saved(unrelated), isEmpty);
      expect(f.store.preference('answerScope.meeting:$meeting'), 'attached');

      f.connection.replies[Operation.meetingsPrepare] = null;
      f.shell.update(() => f.shell.meetingFeature.meetingPanel = 'Preparation');
      await pumpUntil(tester, () => !f.shell.busy);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Prepare from local documents'));
      await pumpUntil(
        tester,
        () => f.connection.calls.any(
          (call) => call.$1 == Operation.meetingsPrepare,
        ),
      );
      final preparation = f.connection.calls.lastWhere(
        (call) => call.$1 == Operation.meetingsPrepare,
      );
      expect(
        preparation.$2['source_ids'],
        unorderedEquals(saved(meeting).expand((item) => item.sourceIds)),
      );

      first.deleteSync();
      File('${folder.path}/Brief.md').writeAsStringSync('# New brief');
      await pumpUntil(
        tester,
        () =>
            !f.shell.busy &&
            find.byTooltip('Refresh meeting attachments').evaluate().isNotEmpty,
      );
      await tester.tap(find.byTooltip('Refresh meeting attachments'));
      await pumpUntil(
        tester,
        () => saved(meeting)
            .where((item) => item.isFolder)
            .single
            .sourceIds
            .any((id) => !attachedFolder.sourceIds.contains(id)),
      );
      await pumpUntil(tester, () => !f.shell.busy);
      final chip = find.widgetWithText(InputChip, 'Meeting references');
      await tester.tap(
        find.descendant(
          of: chip,
          matching: find.byTooltip('Detach from this meeting'),
        ),
      );
      await pumpUntil(tester, () => saved(meeting).length == 1);
      expect(saved(meeting).single.isFolder, isFalse);
      expect(tester.takeException(), isNull);
    }),
  );
}
