import 'package:flutter_test/flutter_test.dart';
import 'package:yue2_studio/setup/requirements.dart';

Hardware hw({double memGb = 32, double diskGb = 100}) => Hardware(memoryBytes: (memGb * Requirements.gib).round(), freeDiskBytes: (diskGb * Requirements.gb).round());

void main() {
  test('thresholds are the contract ones', () {
    expect(Requirements.minMemoryGb, 16);
    expect(Requirements.recommendedMemoryGb, 24);
    expect(Requirements.minFreeDiskGb, 15);
    expect(Requirements.recommendedFreeDiskGb, 25);
  });

  test('memory tiers: under 16 blocked, 16 to under 24 try anyway, 24 and up fine, unknown fine', () {
    expect(memoryTier(hw(memGb: 8)), MemoryTier.blocked);
    expect(memoryTier(hw(memGb: 15.9)), MemoryTier.blocked);
    expect(memoryTier(hw(memGb: 16)), MemoryTier.tryAnyway);
    expect(memoryTier(hw(memGb: 23)), MemoryTier.tryAnyway);
    expect(memoryTier(hw(memGb: 24)), MemoryTier.ok);
    expect(memoryTier(hw(memGb: 128)), MemoryTier.ok);
    expect(memoryTier(const Hardware()), MemoryTier.ok);
  });

  test('preflight is only the free disk: 15 GB passes, less blocks, memory never does', () {
    expect(checkRequirements(hw(diskGb: 14.9)).blocks, [Problem.disk]);
    expect(checkRequirements(hw(diskGb: 15)).ok, isTrue);
    expect(checkRequirements(hw(memGb: 4)).ok, isTrue);
    expect(checkRequirements(const Hardware()).ok, isTrue);
  });

  test('YUE2_STUDIO_TEST_HW overrides the probe values', () {
    final h = Hardware.passing.overridden('mem=8, disk=5 macos=13.2,arch=x86_64');
    expect(h.memoryGb, 8);
    expect(h.freeDiskBytes, 5 * Requirements.gb);
    expect(memoryTier(h), MemoryTier.blocked);
    expect(checkRequirements(h).blocks, [Problem.disk]);
    expect(Hardware.passing.overridden(null), same(Hardware.passing));
    expect(Hardware.passing.overridden('nonsense=1,mem'), isA<Hardware>());
  });
}
