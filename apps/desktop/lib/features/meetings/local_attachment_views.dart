part of 'meetings_controller.dart';

extension _LocalAttachmentViews on MeetingsController {
  Widget _localAttachmentBar(int id, {required bool preview}) {
    final identity = _reads.presentationIdentity;
    final enabled = identity != null && !_operations.busy;
    final attachments = _reads.localAttachments(id);

    void run(Future<void> Function(bool Function() current) action) {
      if (identity == null) return;
      unawaited(
        _runMeetingAction(
          id,
          identity,
          action,
          preview: preview,
        ).catchError(_operations.reportAsyncError),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          PopupMenuButton<bool>(
            tooltip: 'Attach files or a folder to this meeting',
            enabled: enabled,
            icon: const Icon(Icons.attach_file),
            itemBuilder: (_) => const [
              PopupMenuItem(value: false, child: Text('Attach files…')),
              PopupMenuItem(value: true, child: Text('Attach folder…')),
            ],
            onSelected: (folder) => run((current) async {
              final List<String> paths;
              if (folder) {
                final path = await getDirectoryPath();
                if (path == null) return;
                paths = [path];
              } else {
                final files = await openFiles(
                  acceptedTypeGroups: const [
                    XTypeGroup(
                      label: 'Documents',
                      extensions: ['txt', 'md', 'pdf', 'rtf'],
                    ),
                  ],
                );
                paths = files.map((file) => file.path).toList();
              }
              if (!current()) return;
              await _attachLocalPaths(id, paths, folder, current);
            }),
          ),
          if (attachments.isEmpty)
            const Expanded(child: Text('Attach files or a folder'))
          else ...[
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final attachment in attachments)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Tooltip(
                          message: attachment.path,
                          child: InputChip(
                            deleteButtonTooltipMessage:
                                'Detach from this meeting',
                            avatar: Icon(
                              attachment.isFolder
                                  ? Icons.folder_outlined
                                  : Icons.description_outlined,
                            ),
                            label: Text(
                              attachment.sourceIds.isEmpty
                                  ? '${Uri.file(attachment.path).pathSegments.last} (no documents)'
                                  : Uri.file(attachment.path).pathSegments.last,
                              overflow: TextOverflow.ellipsis,
                            ),
                            labelStyle: Theme.of(context).textTheme.bodySmall,
                            onDeleted: enabled
                                ? () => run(
                                    (current) => _saveLocalAttachment(id, {
                                      'path': attachment.path,
                                    }, current),
                                  )
                                : null,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            IconButton(
              tooltip: 'Refresh meeting attachments',
              onPressed: enabled
                  ? () => run((current) async {
                      final saved = await _readLocalAttachments(id);
                      if (!current()) return;
                      for (final attachment in saved) {
                        await _importLocalAttachment(
                          id,
                          attachment.path,
                          attachment.isFolder,
                          current,
                          refresh: true,
                        );
                        if (!current()) return;
                      }
                    })
                  : null,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ],
      ),
    );
  }

  Future<List<MeetingLocalAttachment>> _readLocalAttachments(int id) async =>
      MeetingLocalAttachment.decodeList(
        await readCurrentMeeting(
          d.store,
          StoreReadQueries.preference(
            MeetingLocalAttachment.preferenceKey(id),
            '[]',
          ),
        ),
      );

  Future<void> _saveLocalAttachment(
    int id,
    Map<String, Object?> mutation,
    bool Function() current,
  ) => preferencesSetDescriptor.sendCurrent(
    d,
    PreferencesSetInput(
      key: MeetingLocalAttachment.preferenceKey(id),
      value: jsonEncode(mutation),
      envelope: ClientEnvelope(
        workspaceEpoch: WireField(d.store.workspaceEpoch),
      ),
    ),
    current,
  );

  Future<void> _attachLocalPaths(
    int id,
    List<String> paths,
    bool folder,
    bool Function() current,
  ) async {
    if (paths.length > MeetingLocalAttachment.maxSources) {
      throw StateError('A meeting can use up to 100 attached documents.');
    }
    final failures = <String>[];
    for (final path in paths) {
      if (!current()) return;
      try {
        final canonical = await (folder ? Directory(path) : File(path))
            .resolveSymbolicLinks();
        if (!current()) return;
        if (Directory(canonical).parent.path == canonical) {
          throw StateError(
            'Choose a folder that contains the meeting materials.',
          );
        }
        await _importLocalAttachment(id, canonical, folder, current);
      } catch (_) {
        if (!current()) return;
        failures.add(Uri.file(path).pathSegments.last);
        if (paths.length == 1) rethrow;
      }
    }
    if (failures.isNotEmpty) {
      throw StateError('Could not attach: ${failures.join(', ')}');
    }
  }

  Future<void> _importLocalAttachment(
    int id,
    String path,
    bool folder,
    bool Function() current, {
    bool refresh = false,
  }) async {
    if (!current()) return;
    final type = await FileSystemEntity.type(path, followLinks: false);
    final expected = folder
        ? FileSystemEntityType.directory
        : FileSystemEntityType.file;
    if (!current()) return;
    final kind = folder ? 'folder' : 'file';
    if (type != expected ||
        await (folder ? Directory(path) : File(path)).resolveSymbolicLinks() !=
            path) {
      if (!current()) return;
      if (refresh) {
        // A missing or redirected path must no longer authorize its old sources.
        await _saveLocalAttachment(id, {
          ...MeetingLocalAttachment(path, kind, const []).toWire(),
          'refresh': true,
        }, current);
        return;
      }
      throw StateError('The selected attachment is unavailable.');
    }

    final files = folder
        ? await enumerateImportFiles(
            path,
            current: current,
            include: (file) => !file.path
                .substring(path.length + 1)
                .split('/')
                .any((part) => part.startsWith('.')),
          )
        : [File(path)];
    if (files.length > MeetingLocalAttachment.maxSources) {
      throw StateError('A meeting can use up to 100 attached documents.');
    }
    final sources = <String>[];
    final failures = <String>[];
    for (final file in files) {
      if (!current()) return;
      try {
        if (await file.resolveSymbolicLinks() != file.path) {
          throw StateError('An attachment changed location before import.');
        }
        if (!current()) return;
        final imported = await sourcesImportFileDescriptor.sendCurrent(
          d,
          SourcesImportFileInput(
            path: file.path,
            envelope: ClientEnvelope(
              workspaceEpoch: WireField(d.store.workspaceEpoch),
            ),
          ),
          current,
        );
        sources.add(imported.id);
      } catch (_) {
        if (!current()) return;
        if (!folder && !refresh) rethrow;
        failures.add(file.uri.pathSegments.last);
      }
    }
    if (!current()) return;
    await _saveLocalAttachment(id, {
      ...MeetingLocalAttachment(path, kind, sources).toWire(),
      if (refresh) 'refresh': true,
    }, current);
    if (failures.isNotEmpty && current()) {
      throw StateError('Could not import: ${failures.join(', ')}');
    }
  }
}
