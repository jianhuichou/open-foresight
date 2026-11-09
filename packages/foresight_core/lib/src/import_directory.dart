import 'dart:io';

import 'rpc_error.dart';

const localImportMaxFileBytes = 10 * 1024 * 1024;
const localImportMaxDirectoryEntries = 10000;
const localImportMaxDirectoryFiles = 1000;

/// Native asynchronous directory/stat operations yield between bounded entries;
/// no recursive listSync or source body reads run on the capture isolate.
Future<List<File>> enumerateImportFiles(
  String path, {
  bool Function()? current,
  bool Function(File)? include,
}) async {
  final files = <File>[];
  var entries = 0;
  var bytes = 0;
  final supported = RegExp(r'\.(txt|md|pdf|rtf)$', caseSensitive: false);
  void checkCurrent() {
    if (!(current?.call() ?? true)) {
      throw RpcError(RpcErrorCode.cancelled, 'Operation cancelled');
    }
  }

  checkCurrent();
  await for (final entry in Directory(
    path,
  ).list(recursive: true, followLinks: false)) {
    checkCurrent();
    if (++entries > localImportMaxDirectoryEntries) {
      throw StateError('Directory entry limit exceeded');
    }
    if (entry is! File ||
        !supported.hasMatch(entry.path) ||
        !(include?.call(entry) ?? true)) {
      continue;
    }
    final stat = await entry.stat();
    checkCurrent();
    if (stat.type != FileSystemEntityType.file ||
        stat.size > localImportMaxFileBytes) {
      throw StateError('Import requires a regular file no larger than 10 MiB');
    }
    bytes += stat.size;
    if (bytes > 100 * 1024 * 1024 ||
        files.length >= localImportMaxDirectoryFiles) {
      throw StateError('Directory import limit exceeded');
    }
    files.add(entry);
  }
  checkCurrent();
  return files;
}
