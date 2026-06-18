import 'dart:convert';
import 'dart:io';

class AuthorizedKeyEntry {
  const AuthorizedKeyEntry({
    required this.index,
    required this.line,
    required this.keyLine,
    required this.enabled,
  });

  final int index;
  final String line;
  final String keyLine;
  final bool enabled;

  String get comment {
    final parts = keyLine.trim().split(RegExp(r'\s+'));
    final keyTypeIndex = parts.indexWhere(_isKeyType);
    if (keyTypeIndex == -1 || keyTypeIndex + 2 >= parts.length) return '';
    return parts.sublist(keyTypeIndex + 2).join(' ');
  }

  String get keyType {
    final parts = keyLine.trim().split(RegExp(r'\s+'));
    for (final part in parts) {
      if (_isKeyType(part)) return part;
    }
    return '';
  }

  String get fingerprintPreview {
    final parts = keyLine.trim().split(RegExp(r'\s+'));
    final keyTypeIndex = parts.indexWhere(_isKeyType);
    if (keyTypeIndex == -1 || keyTypeIndex + 1 >= parts.length) return '';
    final key = parts[keyTypeIndex + 1];
    if (key.length <= 18) return key;
    return '${key.substring(0, 10)}...${key.substring(key.length - 8)}';
  }
}

class AuthorizedKeysManager {
  AuthorizedKeysManager(this.path);

  final String path;

  Future<List<AuthorizedKeyEntry>> list() async {
    final lines = await _readLines();
    final entries = <AuthorizedKeyEntry>[];
    for (var index = 0; index < lines.length; index++) {
      final parsed = _parseEntry(index, lines[index]);
      if (parsed != null) entries.add(parsed);
    }
    return entries;
  }

  Future<void> add(String keyLine) async {
    final normalized = _normalizeKeyLine(keyLine);
    final lines = await _readLines();
    if (lines.isNotEmpty && lines.last.trim().isNotEmpty) {
      lines.add(normalized);
    } else if (lines.isEmpty) {
      lines.add(normalized);
    } else {
      lines[lines.length - 1] = normalized;
    }
    await _writeLines(lines);
  }

  Future<void> edit(int index, String keyLine) async {
    final normalized = _normalizeKeyLine(keyLine);
    final lines = await _readLines();
    _checkIndex(lines, index);
    if (_parseEntry(index, lines[index]) == null) {
      throw StateError('Line $index is not an SSH public key.');
    }
    lines[index] = normalized;
    await _writeLines(lines);
  }

  Future<void> delete(int index) async {
    final lines = await _readLines();
    _checkIndex(lines, index);
    if (_parseEntry(index, lines[index]) == null) {
      throw StateError('Line $index is not an SSH public key.');
    }
    lines.removeAt(index);
    await _writeLines(lines);
  }

  Future<void> disable(int index) async {
    final lines = await _readLines();
    _checkIndex(lines, index);
    final entry = _parseEntry(index, lines[index]);
    if (entry == null) {
      throw StateError('Line $index is not an SSH public key.');
    }
    if (!entry.enabled) return;
    lines[index] = '# disabled: ${entry.line}';
    await _writeLines(lines);
  }

  Future<void> enable(int index) async {
    final lines = await _readLines();
    _checkIndex(lines, index);
    final entry = _parseEntry(index, lines[index]);
    if (entry == null) {
      throw StateError('Line $index is not an SSH public key.');
    }
    if (entry.enabled) return;
    lines[index] = entry.keyLine;
    await _writeLines(lines);
  }

  Future<List<String>> _readLines() async {
    final file = await _ensureFile();
    if (!await file.exists()) return <String>[];
    final content = await file.readAsString();
    return const LineSplitter().convert(content);
  }

  Future<void> _writeLines(List<String> lines) async {
    final file = await _ensureFile();
    final normalized = lines.isEmpty ? '' : '${lines.join('\n')}\n';
    await file.writeAsString(normalized);
  }

  Future<File> _ensureFile() async {
    final file = File(path);
    final type = await FileSystemEntity.type(path);
    if (type == FileSystemEntityType.directory) {
      final directory = Directory(path);
      if (await directory.list().isEmpty) {
        await directory.delete();
        stderr.writeln(
          'Repaired authorized_keys path: replaced empty directory at '
          '$path with a file.',
        );
      } else {
        throw FileSystemException(
          'authorized_keys path is a non-empty directory. Remove it and create '
          'a file instead.',
          path,
        );
      }
    }
    await file.parent.create(recursive: true);
    if (!await file.exists()) {
      await file.create();
    }
    return file;
  }

  AuthorizedKeyEntry? _parseEntry(int index, String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return null;

    var enabled = true;
    var keyLine = trimmed;
    if (trimmed.startsWith('# disabled:')) {
      enabled = false;
      keyLine = trimmed.substring('# disabled:'.length).trim();
    } else if (trimmed.startsWith('#')) {
      return null;
    }

    final parts = keyLine.split(RegExp(r'\s+'));
    if (!parts.any(_isKeyType)) return null;

    return AuthorizedKeyEntry(
      index: index,
      line: line,
      keyLine: keyLine,
      enabled: enabled,
    );
  }

  String _normalizeKeyLine(String keyLine) {
    final normalized = keyLine.trim();
    if (normalized.isEmpty) throw const FormatException('Key cannot be empty.');
    final parts = normalized.split(RegExp(r'\s+'));
    final keyTypeIndex = parts.indexWhere(_isKeyType);
    if (keyTypeIndex == -1 || keyTypeIndex + 1 >= parts.length) {
      throw const FormatException('Expected an SSH public key line.');
    }
    return normalized;
  }

  void _checkIndex(List<String> lines, int index) {
    if (index < 0 || index >= lines.length) {
      throw StateError('Key line does not exist.');
    }
  }
}

bool _isKeyType(String value) {
  return value == 'ssh-ed25519' ||
      value == 'ssh-rsa' ||
      value == 'ecdsa-sha2-nistp256' ||
      value == 'ecdsa-sha2-nistp384' ||
      value == 'ecdsa-sha2-nistp521' ||
      value.startsWith('sk-ssh-') ||
      value.startsWith('sk-ecdsa-');
}
