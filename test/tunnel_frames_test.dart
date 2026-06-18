import 'dart:typed_data';

import 'package:chrome_it_support_service/port_allocator.dart';
import 'package:chrome_it_support_service/tunnel_frames.dart';
import 'package:test/test.dart';

void main() {
  test('tunnel data frames round trip', () {
    final encoded = TunnelFrame(
      type: TunnelFrameType.data,
      streamId: 17,
      data: Uint8List.fromList(<int>[0, 1, 2, 255]),
    ).encode();
    final decoded = TunnelFrame.decode(encoded);

    expect(decoded.type, TunnelFrameType.data);
    expect(decoded.streamId, 17);
    expect(decoded.data, <int>[0, 1, 2, 255]);
  });

  test('port allocator uses fixed range and releases ports', () {
    final allocator = PortAllocator(41000, 41001);
    expect(allocator.allocate(), 41000);
    expect(allocator.allocate(), 41001);
    expect(allocator.allocate(), isNull);
    allocator.release(41000);
    expect(allocator.allocate(), 41000);
  });
}
