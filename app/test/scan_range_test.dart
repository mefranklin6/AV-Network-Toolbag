import 'package:av_network_toolbag/scan_range.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('workers cover the subnet exactly once, including short ranges', () {
    for (final count in [1, 2, 254, 65534]) {
      final addresses = [
        for (var worker = 0; worker < 8; worker++)
          ...scanWorkerAddresses(
            0xc0000200 + worker,
            0xc0000200 + count - 1,
            8,
          ),
      ];
      expect(addresses.length, count);
      expect(addresses.toSet().length, count);
    }
  });
  test('large ranges are lazy and cross octet boundaries', () {
    expect(scanWorkerAddresses(0x0a0000fe, 0x0affffff, 1).take(3), [
      '10.0.0.254',
      '10.0.0.255',
      '10.0.1.0',
    ]);
  });
  test('scan limit accepts /16 and rejects larger subnets', () {
    expect(() => validateScanSize(65534), returnsNormally);
    expect(() => validateScanSize(131070), throwsArgumentError);
    expect(() => validateScanSize(16777214), throwsArgumentError);
  });
}
