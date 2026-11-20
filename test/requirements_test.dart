import 'package:flutter_test/flutter_test.dart';
import 'package:yue2_studio/setup/requirements.dart';

Hardware hw({bool arm64 = true, String macos = '15.1', double memGb = 32, double diskGb = 100}) => Hardware(
      arm64: arm64,
      macos: macos,
      memoryBytes: (memGb * Requirements.gib).round(),
      freeDiskBytes: (diskGb * Requirements.gb).round(),
    );

void main() {
  test('thresholds are the contract ones', () {
    expect(Requirements.minMacOS, 14);
    expect(Requirements.minMemoryGb, 16);
    expect(Requirements.recommendedMemoryGb, 24);
    expect(Requirements.minFreeDiskGb, 15);
    expect(Requirements.recommendedFreeDiskGb, 25);
  });

  test('a recommended machine passes with no warning', () {
    final p = checkRequirements(hw(memGb: 24, diskGb: 25));
    expect(p.ok, isTrue);
    expect(p.warnMemory, isFalse);
  });

  test('Intel Mac blocks', () => expect(checkRequirements(hw(arm64: false)).blocks, [Problem.intel]));

  test('macOS older than 14 blocks, 14 and later pass', () {
    expect(checkRequirements(hw(macos: '13.6.7')).blocks, [Problem.macos]);
    expect(checkRequirements(hw(macos: '12.0')).blocks, [Problem.macos]);
    expect(checkRequirements(hw(macos: '14.0')).ok, isTrue);
    expect(checkRequirements(hw(macos: '26.0')).ok, isTrue);
  });

  test('less than 16 GB memory blocks, exactly 16 passes with the warning', () {
    expect(checkRequirements(hw(memGb: 8)).blocks, [Problem.memory]);
    expect(checkRequirements(hw(memGb: 15.9)).blocks, [Problem.memory]);
    final p = checkRequirements(hw(memGb: 16));
    expect(p.ok, isTrue);
    expect(p.warnMemory, isTrue);
    expect(checkRequirements(hw(memGb: 24)).warnMemory, isFalse);
  });

  test('less than 15 GB free disk blocks, 15 passes', () {
    expect(checkRequirements(hw(diskGb: 14.9)).blocks, [Problem.disk]);
    expect(checkRequirements(hw(diskGb: 15)).ok, isTrue);
  });

  test('several problems are all reported, in order', () {
    expect(checkRequirements(hw(arm64: false, macos: '12.0', memGb: 8, diskGb: 3)).blocks, [Problem.intel, Problem.macos, Problem.memory, Problem.disk]);
  });

  test('values the probe could not read never block', () {
    expect(checkRequirements(const Hardware()).ok, isTrue);
  });

  test('YUE2_STUDIO_TEST_HW overrides the probe values', () {
    final h = Hardware.passing.overridden('mem=8, disk=5 macos=13.2,arch=x86_64');
    expect(h.memoryGb, 8);
    expect(h.freeDiskBytes, 5 * Requirements.gb);
    expect(h.macosMajor, 13);
    expect(h.arm64, isFalse);
    expect(checkRequirements(h).blocks.length, 4);
    expect(Hardware.passing.overridden(null), same(Hardware.passing));
    expect(Hardware.passing.overridden('nonsense=1,mem'), isA<Hardware>());
  });
}
