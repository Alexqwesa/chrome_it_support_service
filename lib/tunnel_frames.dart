import 'dart:convert';
import 'dart:typed_data';

enum TunnelFrameType {
  register,
  registered,
  open,
  data,
  close,
  error,
  heartbeat
}

class TunnelFrame {
  const TunnelFrame({
    required this.type,
    this.streamId,
    this.data,
    this.message,
    this.metadata = const <String, Object?>{},
  });

  final TunnelFrameType type;
  final int? streamId;
  final Uint8List? data;
  final String? message;
  final Map<String, Object?> metadata;

  String encode() {
    return jsonEncode(<String, Object?>{
      'type': type.name,
      if (streamId != null) 'streamId': streamId,
      if (data != null) 'base64': base64Encode(data!),
      if (message != null) 'message': message,
      ...metadata,
    });
  }

  static TunnelFrame decode(Object? raw) {
    if (raw is! String) {
      throw const FormatException('Tunnel frames must be JSON text.');
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Tunnel frame must be a JSON object.');
    }
    final typeName = decoded['type'];
    if (typeName is! String) {
      throw const FormatException('Tunnel frame type is missing.');
    }
    final type = TunnelFrameType.values.firstWhere(
      (candidate) => candidate.name == typeName,
      orElse: () => throw FormatException('Unknown tunnel frame: $typeName'),
    );
    final streamId = decoded['streamId'];
    final encodedData = decoded['base64'];
    final message = decoded['message'];
    return TunnelFrame(
      type: type,
      streamId: streamId is int ? streamId : null,
      data: encodedData is String ? base64Decode(encodedData) : null,
      message: message is String ? message : null,
      metadata: Map<String, Object?>.from(decoded)
        ..remove('type')
        ..remove('streamId')
        ..remove('base64')
        ..remove('message'),
    );
  }
}
