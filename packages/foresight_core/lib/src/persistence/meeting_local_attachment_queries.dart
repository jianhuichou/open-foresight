import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../read_models.dart';
import '../rpc_error.dart';

/// Compatibility with the desktop preference transport. Each mutation updates
/// one attachment and its membership atomically.
final class MeetingLocalAttachmentQueries {
  const MeetingLocalAttachmentQueries(this.db);
  final Database db;
  static const prefix = 'meetingLocalAttachments.';

  static int? owner(String key) {
    if (!key.startsWith(prefix)) return null;
    final value = key.substring(prefix.length);
    final meeting = int.tryParse(value);
    return meeting != null && meeting > 0 && '$meeting' == value
        ? meeting
        : null;
  }

  String read(int meeting) {
    final attachments = <String, MeetingLocalAttachment>{};
    for (final row in db.select(
      """
      SELECT a.path,a.kind,s.id FROM meeting_local_attachments a
      LEFT JOIN meeting_local_attachment_items i
        ON i.meeting_id=a.meeting_id AND i.path=a.path
      LEFT JOIN sources s ON s.id=i.source_id AND s.deleted=0
      WHERE a.meeting_id=? ORDER BY a.path,s.id
      """,
      [meeting],
    )) {
      final path = row['path'] as String;
      final attachment = attachments.putIfAbsent(
        path,
        () => MeetingLocalAttachment(path, row['kind'] as String, []),
      );
      if (row['id'] case final String id) attachment.sourceIds.add(id);
    }
    return jsonEncode(attachments.values.map((item) => item.toWire()).toList());
  }

  Never _invalid(String message) =>
      throw RpcError(RpcErrorCode.invalidArgument, message);

  void write(int meeting, String value) {
    final Object? decoded;
    try {
      decoded = jsonDecode(value);
    } on FormatException {
      _invalid('Invalid meeting attachment');
    }
    if (decoded is! Map<String, dynamic> ||
        decoded['path'] is! String ||
        decoded.keys.any(
          (key) =>
              !const {'path', 'kind', 'source_ids', 'refresh'}.contains(key),
        )) {
      _invalid('Invalid meeting attachment');
    }
    final path = decoded['path'] as String;
    final kind = decoded['kind'];
    final ids = decoded['source_ids'];
    final refresh = decoded['refresh'];
    if ((refresh != null && refresh != true) ||
        !p.isAbsolute(path) ||
        path == p.rootPrefix(path) ||
        p.normalize(path) != path ||
        path.length > 4096 ||
        path.contains(String.fromCharCode(0)) ||
        (kind != null && kind != 'file' && kind != 'folder') ||
        (kind == null ? ids != null || refresh != null : ids is! List)) {
      _invalid('Invalid meeting attachment path or kind');
    }
    final sourceIds = <String>{};
    if (ids is List) {
      if (ids.length > MeetingLocalAttachment.maxSources ||
          ids.any((id) => id is! String)) {
        _invalid('A meeting can use up to 100 attached documents');
      }
      sourceIds.addAll(ids.cast<String>());
    }
    if (kind == 'file' && sourceIds.length > 1) {
      _invalid('A file attachment can have only one document');
    }

    db.execute('SAVEPOINT write_meeting_local_attachment');
    try {
      if (db.select('SELECT 1 FROM meetings WHERE id=?', [meeting]).isEmpty) {
        _invalid('Meeting no longer exists');
      }
      if (kind == null) {
        db.execute(
          'DELETE FROM meeting_local_attachments WHERE meeting_id=? AND path=?',
          [meeting, path],
        );
      } else {
        final existing = db.select(
          'SELECT kind FROM meeting_local_attachments WHERE meeting_id=? AND path=?',
          [meeting, path],
        ).firstOrNull;
        if (refresh == true && existing == null) {
          _invalid('The attachment was removed before the refresh finished');
        }
        final attachmentCount =
            db.select(
                  'SELECT COUNT(*) AS total FROM meeting_local_attachments WHERE meeting_id=?',
                  [meeting],
                ).single['total']
                as int;
        if (existing == null &&
            attachmentCount >= MeetingLocalAttachment.maxSources) {
          _invalid('A meeting can have up to 100 attachment entries');
        }
        final allIds = {
          ...sourceIds,
          for (final row in db.select(
            """
            SELECT s.id FROM meeting_local_attachment_items i
            JOIN sources s ON s.id=i.source_id AND s.deleted=0
            WHERE i.meeting_id=? AND i.path<>?
            """,
            [meeting, path],
          ))
            row['id'] as String,
        };
        if (allIds.length > MeetingLocalAttachment.maxSources) {
          _invalid('A meeting can use up to 100 attached documents');
        }
        for (final sourceId in sourceIds) {
          final sourceUri = db
              .select(
                """
            SELECT d.source_uri FROM source_details d
            JOIN sources s ON s.id=d.source_id AND s.deleted=0 AND s.generated=0
            WHERE s.id=?
            """,
                [sourceId],
              )
              .firstOrNull?['source_uri'];
          final uri = sourceUri is String ? Uri.tryParse(sourceUri) : null;
          String? file;
          if (uri != null &&
              uri.scheme == 'file' &&
              uri.host.isEmpty &&
              !uri.hasQuery &&
              !uri.hasFragment) {
            try {
              file = p.normalize(uri.toFilePath());
            } on UnsupportedError {
              _invalid('The selected source does not have a local file path');
            }
          }
          if (file == null ||
              !p.isAbsolute(file) ||
              (kind == 'file' ? file != path : !p.isWithin(path, file))) {
            _invalid(
              'Each attachment document must come from its selected path',
            );
          }
        }
        db.execute(
          """
          INSERT INTO meeting_local_attachments(meeting_id,path,kind) VALUES(?,?,?)
          ON CONFLICT(meeting_id,path) DO UPDATE SET kind=excluded.kind
          """,
          [meeting, path, kind],
        );
        db.execute(
          'DELETE FROM meeting_local_attachment_items WHERE meeting_id=? AND path=?',
          [meeting, path],
        );
        for (final sourceId in sourceIds) {
          db.execute(
            'INSERT INTO meeting_local_attachment_items(meeting_id,path,source_id) VALUES(?,?,?)',
            [meeting, path, sourceId],
          );
        }
        if (existing == null) {
          // Adding a new attachment is an explicit request to use this context.
          db.execute(
            """
            INSERT INTO conversation_scopes(conversation,meeting_id,mode)
            VALUES(?,?,'attached') ON CONFLICT(conversation) DO UPDATE SET mode='attached'
            """,
            ['meeting:$meeting', meeting],
          );
          db.execute(
            """
            INSERT INTO proactive_scopes(meeting_id,mode) VALUES(?,'attached')
            ON CONFLICT(meeting_id) DO UPDATE SET mode='attached'
            """,
            [meeting],
          );
        }
      }
      db.execute('RELEASE write_meeting_local_attachment');
    } catch (_) {
      if (!db.autocommit) {
        db.execute('ROLLBACK TO write_meeting_local_attachment');
        db.execute('RELEASE write_meeting_local_attachment');
      }
      rethrow;
    }
  }
}
