import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// POSIX counterpart of [WindowsStorage] for the desktop save path.
///
/// A finished payload is written to `<target>/.asterlink-cache/...` and then
/// published into `<target>`. Both live on the same file system, so publishing
/// is a hard link: no bytes are copied and the payload keeps its resumable
/// cache entry until the completed task is durable.
///
/// Windows asked `CreateHardLinkW`; every other desktop used to fall through to
/// a full read+write copy of the payload, which turned a 1 GiB download into a
/// minute of disk churn for no reason.
///
/// Everything here degrades to `null` (unknown device / unsupported hard link)
/// so the caller can fall back to copying on file systems that cannot link,
/// such as exFAT or a FAT32 stick.
class PosixStorage {
  static final DynamicLibrary? _libc = _openLibc();

  static DynamicLibrary? _openLibc() {
    if (Platform.isWindows) return null;
    for (final name in <String?>['libc.so.6', null]) {
      try {
        return name == null ? DynamicLibrary.process() : DynamicLibrary.open(name);
      } catch (_) {
        // Try the next spelling; a miss only costs the copy path below.
      }
    }
    return null;
  }

  static final _StatDart? _stat = _lookupStat(_libc);
  static final _LinkDart? _link = _lookupLink(_libc);

  static _StatDart? _lookupStat(DynamicLibrary? library) {
    if (library == null) return null;
    try {
      return library.lookupFunction<_StatNative, _StatDart>('stat');
    } catch (_) {
      return null;
    }
  }

  static _LinkDart? _lookupLink(DynamicLibrary? library) {
    if (library == null) return null;
    try {
      return library.lookupFunction<_LinkNative, _LinkDart>('link');
    } catch (_) {
      return null;
    }
  }

  /// Identifies the file system holding [path], or null when it cannot be read.
  ///
  /// `st_dev` is the first field of `struct stat` on every glibc architecture we
  /// ship for, so the leading machine word is enough to tell `<target>` and its
  /// `.asterlink-cache` apart from a payload that was somehow written elsewhere.
  static int? device(String path) {
    final stat = _stat;
    if (stat == null) return null;
    final native = path.toNativeUtf8();
    // glibc x86_64/aarch64 `struct stat` is 144 bytes; 256 leaves headroom.
    final buffer = calloc<Uint8>(256);
    try {
      if (stat(native, buffer) != 0) return null;
      return buffer.cast<Uint64>().value;
    } finally {
      calloc.free(native);
      calloc.free(buffer);
    }
  }

  static final _linkSupport = <int, bool>{};

  /// Whether [directory] accepts new hard links.
  ///
  /// The file system *type* is not a reliable answer. ext4, XFS, btrfs and NTFS
  /// (ntfs-3g, `fuseblk`) all link, while exFAT, FAT32 and most network shares
  /// answer EPERM. Guessing "same device ⇒ links work" made the download's space
  /// reservation promise one copy on volumes that later need two, so the failure
  /// only surfaced at save time — after the bytes were already on disk.
  ///
  /// Publishing therefore asks the volume itself once, with a 0-byte file and a
  /// second name for it, and remembers the answer per `st_dev` for this process.
  /// A negative answer keeps the reservation at two copies, matching the copy
  /// fallback in `save`.
  static bool supportsHardLinks(String directory) {
    final device = PosixStorage.device(directory);
    if (device == null) return false;
    final cached = _linkSupport[device];
    if (cached != null) return cached;

    final separator = directory.endsWith('/') ? '' : '/';
    final probe = '$directory$separator'
        '.asterlink-linkprobe-$pid-${DateTime.now().microsecondsSinceEpoch}';
    final second = '$probe.link';
    var supported = false;
    try {
      File(probe).writeAsBytesSync(const <int>[], flush: true);
      createHardLink(probe, second);
      supported = true;
    } on FileSystemException catch (error) {
      // ENOSPC (28) / EDQUOT (122) mean the volume is full, not that it cannot
      // link: `link` itself allocates no data blocks, and turning a full disk
      // into "copy the payload instead" would ask for a second full copy.
      final code = error.osError?.errorCode;
      supported = code == 28 || code == 122;
    } catch (_) {
      supported = false;
    } finally {
      for (final path in <String>[probe, second]) {
        try {
          final file = File(path);
          if (file.existsSync()) file.deleteSync();
        } catch (_) {
          // A leftover probe is harmless; never fail a plan over cleanup.
        }
      }
    }
    return _linkSupport[device] = supported;
  }

  /// Creates `target` as a second name for `source`.
  ///
  /// Mirrors [WindowsStorage.createHardLink]: throws [FileSystemException] when
  /// the link cannot be made, so the caller can tell "name already taken" from
  /// "this file system has no hard links" by checking whether `target` exists.
  static void createHardLink(String source, String target) {
    final link = _link;
    if (link == null) {
      throw FileSystemException('无法发布下载文件', target);
    }
    final existing = source.toNativeUtf8();
    final output = target.toNativeUtf8();
    try {
      if (link(existing, output) == 0) return;
      throw FileSystemException('无法发布下载文件', target);
    } finally {
      calloc.free(existing);
      calloc.free(output);
    }
  }
}

typedef _StatNative = Int32 Function(Pointer<Utf8>, Pointer<Uint8>);
typedef _StatDart = int Function(Pointer<Utf8>, Pointer<Uint8>);
typedef _LinkNative = Int32 Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _LinkDart = int Function(Pointer<Utf8>, Pointer<Utf8>);
