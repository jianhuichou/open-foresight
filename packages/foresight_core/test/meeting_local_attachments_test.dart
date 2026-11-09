import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/src/answer_source_scope.dart';
import 'package:foresight_core/src/persistence/application_queries.dart';
import 'package:foresight_core/src/persistence/schema_migrations.dart';
import 'package:foresight_core/src/persistence/sqlite_runtime.dart';
import 'package:foresight_core/src/read_models.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

import 'sql_support_test_bootstrap.dart';

void main() {
  bootstrapSqlSupportFixture();
  late Directory root;
  late Store store;
  late String path;

  setUp(() {
    root = createTestTempDirectorySync('attach-');
    path = '${root.path}/application.db';
    store = Store(path);
    addTearDown(() => store.close());
  });

  String import(String path) => store.importText(
    path,
    'Attachment body',
    'text/plain',
    'fixture',
    sourceUri: Uri.file(path).toString(),
  );

  void attach(
    int meeting,
    String path,
    String kind,
    List<String> ids, {
    bool refresh = false,
  }) => store.setPreference(
    MeetingLocalAttachment.preferenceKey(meeting),
    jsonEncode({
      ...MeetingLocalAttachment(path, kind, ids).toWire(),
      if (refresh) 'refresh': true,
    }),
  );

  List<MeetingLocalAttachment> attachments(int meeting) =>
      MeetingLocalAttachment.decodeList(
        store.preference(MeetingLocalAttachment.preferenceKey(meeting), '[]'),
      );

  AnswerSourceScope scope(int meeting, {bool automatic = false}) =>
      AnswerSourceScope.read(
        store,
        'meeting:$meeting',
        meeting: meeting,
        automatic: automatic,
      );

  test('folders and files persist per meeting and share imported files', () {
    final first = store.meeting('First');
    final second = store.meeting('Second');
    final notes = import('/work/design/notes.md');
    final agenda = import('/work/design/agenda.md');
    final other = import('/work/grant/agenda.md');
    expect(scope(first).ids, isNull);
    attach(first, '/work/design', 'folder', [notes, agenda]);
    attach(second, '/work/design/notes.md', 'file', [notes]);

    store.close();
    store = Store(path);
    expect(attachments(first).single.path, '/work/design');
    expect(
      attachments(first).single.sourceIds,
      unorderedEquals([notes, agenda]),
    );
    expect(attachments(second).single.sourceIds, [notes]);
    expect(scope(first).ids, containsAll([notes, agenda, 'meeting-$first']));
    expect(scope(first).ids, isNot(contains(other)));
    expect(scope(first).ids, isNot(contains('meeting-preparation-$first')));
    expect(scope(first, automatic: true).ids, scope(first).ids);
    expect(scope(second).ids, isNot(contains(agenda)));
  });

  test('refresh replaces membership and detach cannot widen scope', () {
    final id = store.meeting('Review');
    final first = import('/work/design/old.md');
    final second = import('/work/design/new.md');
    final key = MeetingLocalAttachment.preferenceKey(id);
    attach(id, '/work/design', 'folder', [first]);
    final prior = scope(id);
    attach(id, '/work/design', 'folder', [second], refresh: true);
    expect(scope(id).ids, contains(second));
    expect(scope(id).ids, isNot(contains(first)));
    expect(scope(id).identity, isNot(prior.identity));
    store.setPreference(key, '{"path":"/work/design"}');
    expect(attachments(id), isEmpty);
    expect(scope(id).mode, 'attached');
    expect(scope(id).ids, isNot(contains(second)));
    expect(scope(id).ids, contains('meeting-$id'));
    expect(
      () => attach(id, '/work/design', 'folder', [first], refresh: true),
      throwsA(isA<RpcError>()),
    );
    expect(store.sourceById(first), hasLength(1));
  });

  test('wrong paths, remote sources and a missing meeting fail atomically', () {
    final id = store.meeting('Review');
    final first = import('/work/design/notes.md');
    final other = import('/work/design-old/notes.md');
    final remote = store.importText(
      'Remote',
      'Attachment',
      'text/plain',
      'fixture',
      sourceUri: 'https://example.test/notes',
    );
    attach(id, '/work/design', 'folder', [first]);
    for (final bad in [other, remote, 'missing']) {
      expect(
        () => attach(id, '/work/design', 'folder', [bad]),
        throwsA(isA<RpcError>()),
      );
      expect(attachments(id).single.sourceIds, [first]);
    }
    expect(
      () => attach(id + 1, '/work/design', 'folder', [first]),
      throwsA(isA<RpcError>()),
    );
    expect(store.rows('PRAGMA foreign_key_check'), isEmpty);
  });

  test('migration preserves old meeting scope and clear erases owned rows', () {
    store.close();
    path = '${root.path}/legacy.db';
    final original = openApplicationDatabase(path);
    for (var version = 1; version <= 25; version++) {
      ApplicationMigrations(original).run(version);
    }
    original.execute(
      "INSERT INTO meetings(id,title,state) VALUES(7,'Existing','idle')",
    );
    original.execute("INSERT INTO proactive_scopes VALUES(7,'meeting')");
    original.execute('PRAGMA user_version=25');
    original.dispose();
    store = Store(path);
    expect(attachments(7), isEmpty);
    expect(scope(7, automatic: true).mode, 'meeting');
    final notes = import('/work/design/notes.md');
    attach(7, '/work/design', 'folder', [notes]);
    WorkspacePersistence(store).clearLocalData([notes]);
    expect(store.rows('SELECT * FROM meeting_local_attachments'), isEmpty);
    expect(store.rows('SELECT * FROM meeting_local_attachment_items'), isEmpty);
    expect(store.rows('PRAGMA foreign_key_check'), isEmpty);
  });
}
