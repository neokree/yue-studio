import 'dart:io';

/// System requirements and the preflight (CONTRACT.md section 2 table and section 3.1). The only place with the thresholds.
/// Apple Silicon and macOS 14 are enforced by macOS itself (arm64-only binary, LSMinimumSystemVersion): no app logic for them.
/// Memory is in GiB (a "16 GB" Mac reports 16 * 2^30 bytes); disk is decimal GB, as df and the manifest count.
class Requirements {
  /// Below this the requirements page has no way forward.
  static const minMemoryGb = 16;

  /// Below this (and from [minMemoryGb] up) the requirements page offers "Try anyway".
  static const recommendedMemoryGb = 24;
  static const minFreeDiskGb = 15;
  static const recommendedFreeDiskGb = 25;

  static const gib = 1073741824;
  static const gb = 1000000000;
}

/// What the probe found. null = could not be told: never blocks (a false block is worse than a late failure).
class Hardware {
  const Hardware({this.memoryBytes, this.freeDiskBytes});

  final int? memoryBytes, freeDiskBytes;

  double? get memoryGb => memoryBytes == null ? null : memoryBytes! / Requirements.gib;

  /// A machine that meets the recommended specs: what tests see on Linux.
  static const passing = Hardware(memoryBytes: 32 * Requirements.gib, freeDiskBytes: 100 * Requirements.gb);

  /// Test override, YUE2_STUDIO_TEST_HW="mem=8,disk=5" (GB). Unknown keys are ignored.
  Hardware overridden(String? spec) {
    if (spec == null || spec.trim().isEmpty) return this;
    var h = this;
    for (final part in spec.trim().split(RegExp(r'[,;\s]+'))) {
      final kv = part.split('=');
      final n = kv.length == 2 ? num.tryParse(kv[1].trim()) : null;
      if (n == null) continue;
      h = switch (kv[0].trim()) {
        'mem' => Hardware(memoryBytes: (n * Requirements.gib).round(), freeDiskBytes: h.freeDiskBytes),
        'disk' => Hardware(memoryBytes: h.memoryBytes, freeDiskBytes: (n * Requirements.gb).round()),
        _ => h,
      };
    }
    return h;
  }
}

/// What the requirements page does for this Mac's memory. Unknown memory is [ok]: the page never blocks on a guess.
enum MemoryTier { ok, tryAnyway, blocked }

MemoryTier memoryTier(Hardware h) {
  final mem = h.memoryGb;
  if (mem == null || mem >= Requirements.recommendedMemoryGb) return MemoryTier.ok;
  return mem >= Requirements.minMemoryGb ? MemoryTier.tryAnyway : MemoryTier.blocked;
}

enum Problem { disk }

class Preflight {
  const Preflight(this.hardware, this.blocks);
  final Hardware hardware;

  /// Problems that stop the install, in display order.
  final List<Problem> blocks;
  bool get ok => blocks.isEmpty;
}

/// Setup's own check: free disk. (Memory is the requirements page, before setup.)
Preflight checkRequirements(Hardware h) {
  final disk = h.freeDiskBytes;
  return Preflight(h, [if (disk != null && disk < Requirements.minFreeDiskGb * Requirements.gb) Problem.disk]);
}

typedef FreeBytes = Future<int?> Function(String dir);

/// Free bytes on the volume holding [dir] (null when it can't be told: don't block setup).
Future<int?> dfFreeBytes(String dir) async {
  try {
    final r = await Process.run('df', ['-Pk', dir]);
    final cols = (r.stdout as String).trim().split('\n').last.split(RegExp(r'\s+'));
    return int.parse(cols[3]) * 1024;
  } catch (_) {
    return null;
  }
}

/// Reads the machine. An interface so tests inject values instead of the real Mac.
abstract class HardwareProbe {
  Future<Hardware> read(String dataDir);
}

class SystemProbe implements HardwareProbe {
  SystemProbe({this.freeBytes = dfFreeBytes});
  final FreeBytes freeBytes;

  @override
  Future<Hardware> read(String dataDir) async {
    // Not macOS (Linux in Docker tests): a passing machine, unless YUE2_STUDIO_TEST_HW says otherwise.
    final real = Platform.isMacOS ? await _mac(dataDir) : Hardware.passing;
    return real.overridden(Platform.environment['YUE2_STUDIO_TEST_HW']);
  }

  Future<Hardware> _mac(String dataDir) async {
    final mem = int.tryParse(await _out('sysctl', ['-n', 'hw.memsize']) ?? '');
    // The data dir doesn't exist yet on first run: ask about the closest folder that does (same volume).
    var dir = Directory(dataDir);
    while (!dir.existsSync() && dir.parent.path != dir.path) {
      dir = dir.parent;
    }
    return Hardware(memoryBytes: mem, freeDiskBytes: await freeBytes(dir.path));
  }

  Future<String?> _out(String exe, List<String> args) async {
    try {
      final r = await Process.run(exe, args);
      return r.exitCode == 0 ? (r.stdout as String).trim() : null;
    } catch (_) {
      return null;
    }
  }
}
