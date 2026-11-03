// ignore_for_file: avoid_print
import 'dart:io';

import 'package:asterlink/platform/posix_storage.dart';

/// Exercises the desktop publication primitive on real volumes.
///
/// `dart run tool/posix_storage_check.dart [directory...]` — the default run
/// uses a temp dir; pass mount points (e.g. an NTFS or exFAT disk) to check what
/// the app will decide there. Prints only PASS/FAIL style lines, never data.
void main(List<String> arguments) {
  final temporary = Directory.systemTemp.createTempSync('posix-check-');
  try {
    report('temp (${temporary.path})', temporary.path);
  } finally {
    temporary.deleteSync(recursive: true);
  }
  for (final path in arguments) {
    try {
      if (!Directory(path).existsSync()) {
        print('skip $path (missing)');
        continue;
      }
      report(path, path);
    } on FileSystemException catch (error) {
      print('$path: unusable here (${error.osError?.message})');
    }
  }
}

void report(String label, String directory) {
  final device = PosixStorage.device(directory);
  final links = PosixStorage.supportsHardLinks(directory);
  print('$label: device=$device hardLinks=$links');
  print('  probe residue = ${_residue(directory)}');

  if (!links) {
    print('  publish       = copy (reservation must stay at two copies)');
    return;
  }

  // The payload must live on the same volume as the published name, exactly as
  // `<target>/.asterlink-cache/<id>/payload` does.
  final token = '.asterlink-publish-check-$pid';
  final cache = Directory('$directory/$token')..createSync();
  final source = File('${cache.path}/payload')
    ..writeAsBytesSync(List<int>.generate(1024, (i) => i % 251));
  final target = '$directory/$token.bin';
  try {
    PosixStorage.createHardLink(source.path, target);
    print('  identical     = '
        '${FileSystemEntity.identicalSync(source.path, target)}');
    source.deleteSync();
    print('  after cache deletion = ${File(target).readAsBytesSync().length}'
        ' bytes');
    // Recreate the payload so the collision case is a real "name taken",
    // not a missing source.
    source.writeAsBytesSync(const [7]);
    print('  collision     = ${_collision(source.path, target)}');
  } finally {
    if (File(target).existsSync()) File(target).deleteSync();
    if (cache.existsSync()) cache.deleteSync(recursive: true);
  }
}

int _residue(String directory) => Directory(directory)
    .listSync()
    .where((entry) => entry.path.contains('.asterlink-linkprobe-'))
    .length;

String _collision(String source, String target) {
  try {
    PosixStorage.createHardLink(source, target);
    return 'NO EXCEPTION (bad)';
  } on FileSystemException {
    return 'threw, target exists = ${File(target).existsSync()}';
  }
}
