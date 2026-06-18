String secretFingerprint(String? value) {
  if (value == null || value.isEmpty) return 'empty';
  var hash = 0x811c9dc5;
  for (final unit in value.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return 'len=${value.length}, fnv32=${hash.toRadixString(16).padLeft(8, '0')}';
}
