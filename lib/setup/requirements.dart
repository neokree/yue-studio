import 'dart:io';

/// System requirements and the preflight (CONTRACT.md section 2 table and section 3.1). The only place with the thresholds.
/// Memory is in GiB (a "16 GB" Mac reports 16 * 2^30 bytes); disk is decimal GB, as df and the manifest count.
class Requirements {
  static const minMacOS = 14;
  static const minMemoryGb = 16;
  static const recommendedMemoryGb = 24;
  static const minFreeDiskGb = 15;
  static const recommendedFreeDiskGb = 25;

  /// The non-blocking warning shows at exactly this much memory (16 GB up to, not including, 17 GB).
  static const warnMemoryGb = 16;

  static const gib = 1073741824;
  static const gb = 1000000000;
}

/// What the probe found. null = could not be told: never blocks (a false block is worse than a late failure).
class Hardware {
  const Hardware({this.arm64, this.macos, this.memoryBytes, this.freeDiskBytes});

  /// Apple Silicon.
  final bool? arm64;

  /// Product version, "14.5" or "15.1.2".
  final String? macos;
  final int? memoryBytes, freeDiskBytes;

  int? get macosMajor => macos == null ? null : int.tryParse(macos!.split('.').first);
  double? get memoryGb => memoryBytes == null ? null : memoryBytes! / Requirements.gib;

  /// A machine that meets the recommended specs: what tests see on Linux.
  static const passing = Hardware(arm64: true, macos: '15.0', memoryBytes: 32 * Requirements.gib, freeDiskBytes: 100 * Requirements.gb);

  /// Test override, YUE2_STUDIO_TEST_HW="mem=8,disk=5,macos=13,arch=x86_64" (mem and disk in GB). Unknown keys are ignored.
  Hardware overridden(String? spec) {
    if (spec == null || spec.trim().isEmpty) return this;
    var h = this;
    for (final part in spec.trim().split(RegExp(r'[,;\s]+'))) {
      final kv = part.split('=');
      if (kv.length != 2) continue;
      final v = kv[1].trim();
      final n = num.tryParse(v);
      h = switch (kv[0].trim()) {
        'mem' when n != null => h._with(memoryBytes: (n * Requirements.gib).round()),
        'disk' when n != null => h._with(freeDiskBytes: (n * Requirements.gb).round()),
        'macos' => h._with(macos: v),
        'arch' => h._with(arm64: v == 'arm64'),
        _ => h,
      };
    }
    return h;
  }

  Hardware _with({bool? arm64, String? macos, int? memoryBytes, int? freeDiskBytes}) => Hardware(
        arm64: arm64 ?? this.arm64,
        macos: macos ?? this.macos,
        memoryBytes: memoryBytes ?? this.memoryBytes,
        freeDiskBytes: freeDiskBytes ?? this.freeDiskBytes,
      );
}

enum Problem { intel, macos, memory, disk }

class Preflight {
  const Preflight(this.hardware, this.blocks, {required this.warnMemory});
  final Hardware hardware;

  /// Problems that stop the install, in display order.
  final List<Problem> blocks;

  /// 16 GB: allowed, with a line telling the user to close other apps.
  final bool warnMemory;
  bool get ok => blocks.isEmpty;
}

Preflight checkRequirements(Hardware h) {
  final mem = h.memoryGb, major = h.macosMajor, disk = h.freeDiskBytes;
  return Preflight(
    h,
    [
      if (h.arm64 == false) Problem.intel,
      if (major != null && major < Requirements.minMacOS) Problem.macos,
      if (mem != null && mem < Requirements.minMemoryGb) Problem.memory,
      if (disk != null && disk < Requirements.minFreeDiskGb * Requirements.gb) Problem.disk,
    ],
    warnMemory: mem != null && mem >= Requirements.warnMemoryGb && mem < Requirements.warnMemoryGb + 1,
  );
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
    final arm = await _out('sysctl', ['-n', 'hw.optional.arm64']);
    final arch = arm == null ? await _out('uname', ['-m']) : null;
    final mem = int.tryParse(await _out('sysctl', ['-n', 'hw.memsize']) ?? '');
    // The data dir doesn't exist yet on first run: ask about the closest folder that does (same volume).
    var dir = Directory(dataDir);
    while (!dir.existsSync() && dir.parent.path != dir.path) {
      dir = dir.parent;
    }
    return Hardware(
      arm64: arm != null ? arm == '1' : (arch == null ? null : arch == 'arm64'),
      macos: await _out('sw_vers', ['-productVersion']),
      memoryBytes: mem,
      freeDiskBytes: await freeBytes(dir.path),
    );
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
