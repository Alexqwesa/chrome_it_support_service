import 'dart:convert';
import 'dart:io';

class OperatorRecord {
  OperatorRecord({
    required this.email,
    required this.createdAt,
    required this.createdBy,
    required this.updatedAt,
    required this.updatedBy,
    this.isDeleted = false,
    this.canManageAdmin = false,
    this.canManageOperator = false,
    this.publicKey,
  });

  final String email;
  final String createdAt;
  final String createdBy;
  String updatedAt;
  String updatedBy;
  bool isDeleted;
  bool canManageAdmin;
  bool canManageOperator;
  String? publicKey;

  factory OperatorRecord.fromJson(Map<String, dynamic> json) => OperatorRecord(
        email: json['email'] as String,
        createdAt: json['createdAt'] as String,
        createdBy: json['createdBy'] as String,
        updatedAt: json['updatedAt'] as String,
        updatedBy: json['updatedBy'] as String,
        isDeleted: json['isDeleted'] == true,
        canManageAdmin: json['canManageAdmin'] == true,
        canManageOperator: json['canManageOperator'] == true,
        publicKey: json['publicKey'] as String?,
      );

  Map<String, Object?> toJson() => {
        'email': email,
        'createdAt': createdAt,
        'createdBy': createdBy,
        'updatedAt': updatedAt,
        'updatedBy': updatedBy,
        'isDeleted': isDeleted,
        'canManageAdmin': canManageAdmin,
        'canManageOperator': canManageOperator,
        'publicKey': publicKey,
      };
}

class OperatorStore {
  OperatorStore(this.directory);

  final String directory;
  final Map<String, OperatorRecord> _records = {};
  Future<void> _pending = Future.value();
  Future<void> _journalPending = Future.value();

  File get _usersFile => File('$directory/operators.json');
  File get _keysFile => File('$directory/operator_keys');
  File get _journalFile => File('$directory/journal.jsonl');

  Iterable<OperatorRecord> get users => _records.values;
  OperatorRecord? get(String email) {
    final user = _records[email.trim().toLowerCase()];
    return user?.isDeleted == true ? null : user;
  }

  Future<void> initialize(String? bootstrapEmail) async {
    await Directory(directory).create(recursive: true);
    if (await _usersFile.exists()) {
      final decoded = jsonDecode(await _usersFile.readAsString()) as List;
      for (final item in decoded) {
        final user = OperatorRecord.fromJson((item as Map).cast<String, dynamic>());
        _records[user.email] = user;
      }
    }
    if (_records.isEmpty && bootstrapEmail != null && bootstrapEmail.trim().isNotEmpty) {
      final email = _email(bootstrapEmail);
      final now = DateTime.now().toUtc().toIso8601String();
      _records[email] = OperatorRecord(
        email: email,
        createdAt: now,
        createdBy: 'bootstrap',
        updatedAt: now,
        updatedBy: 'bootstrap',
        canManageAdmin: true,
        canManageOperator: true,
      );
      await _save();
    } else if (!await _usersFile.exists()) {
      await _save();
    }
    await _writeManagedKeys();
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _pending.then((_) => action());
    _pending = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<void> upsertUser(String email, String actor,
      {required bool canManageAdmin, required bool canManageOperator}) =>
      _serial(() async {
        final id = _email(email);
        final now = DateTime.now().toUtc().toIso8601String();
        final user = _records.putIfAbsent(
          id,
          () => OperatorRecord(
            email: id,
            createdAt: now,
            createdBy: actor,
            updatedAt: now,
            updatedBy: actor,
          ),
        );
        user
          ..isDeleted = false
          ..canManageAdmin = canManageAdmin
          ..canManageOperator = canManageOperator
          ..updatedAt = now
          ..updatedBy = actor;
        await _save();
        await journal(actor, 'operator_saved', subject: id,
            details: {'canManageAdmin': canManageAdmin, 'canManageOperator': canManageOperator});
        await _writeManagedKeys();
      });

  Future<void> removeUser(String email, String actor) => _serial(() async {
        final user = get(email);
        if (user == null) throw StateError('Operator not found.');
        if (user.email == actor) throw StateError('Cannot remove yourself.');
        user
          ..isDeleted = true
          ..publicKey = null
          ..updatedAt = DateTime.now().toUtc().toIso8601String()
          ..updatedBy = actor;
        await _save();
        await _writeManagedKeys();
        await journal(actor, 'operator_deleted', subject: user.email);
      });

  Future<void> setOwnKey(String email, String key) => _serial(() async {
        final user = get(email);
        if (user == null) throw StateError('Operator not found.');
        final parts = key.trim().split(RegExp(r'\s+'));
        if (parts.length < 2 ||
            !RegExp(r'^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256)$')
                .hasMatch(parts[0]) ||
            base64Decode(base64.normalize(parts[1])).isEmpty ||
            key.contains('\n') || key.contains('\r')) {
          throw const FormatException('Expected one valid SSH public key.');
        }
        final material = '${parts[0]} ${parts[1]}';
        for (final other in _records.values) {
          if (other.email != email && other.publicKey?.startsWith(material) == true) {
            throw StateError('SSH key is already assigned to another operator.');
          }
        }
        user
          ..publicKey = key.trim()
          ..updatedAt = DateTime.now().toUtc().toIso8601String()
          ..updatedBy = email;
        await _save();
        await _writeManagedKeys();
        await journal(email, 'own_key_replaced', subject: email);
      });

  Future<void> clearOwnKey(String email) => _serial(() async {
        final user = get(email);
        if (user == null) throw StateError('Operator not found.');
        user
          ..publicKey = null
          ..updatedAt = DateTime.now().toUtc().toIso8601String()
          ..updatedBy = email;
        await _save();
        await _writeManagedKeys();
        await journal(email, 'own_key_removed', subject: email);
      });

  Future<void> journal(String actor, String action,
      {String? subject, Map<String, Object?> details = const {}}) {
    final row = {
      'at': DateTime.now().toUtc().toIso8601String(),
      'actor': actor,
      'action': action,
      if (subject != null) 'subject': subject,
      ...details,
    };
    final result = _journalPending.then((_) async {
      await _journalFile.writeAsString('${jsonEncode(row)}\n', mode: FileMode.append);
      stdout.writeln('Journal: ${jsonEncode(row)}');
    });
    _journalPending = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<List<Map<String, dynamic>>> history({String? owner}) async {
    await _journalPending;
    if (!await _journalFile.exists()) return [];
    final rows = (await _journalFile.readAsLines())
        .where((line) => line.isNotEmpty)
        .map((line) => (jsonDecode(line) as Map).cast<String, dynamic>())
        .where((row) => owner == null ||
            (row['subject'] == owner &&
                (row['action'] as String).startsWith('own_key_')))
        .toList();
    return rows.reversed.take(500).toList();
  }

  Future<void> _save() async {
    final temporary = File('${_usersFile.path}.tmp');
    await temporary.writeAsString(jsonEncode(_records.values.map((e) => e.toJson()).toList()));
    await temporary.rename(_usersFile.path);
  }

  Future<void> _writeManagedKeys() async {
    final keys = _records.values
        .where((user) => !user.isDeleted && user.publicKey != null)
        .map((user) => user.publicKey!)
        .join('\n');
    final temporary = File('${_keysFile.path}.tmp');
    await temporary.writeAsString(keys.isEmpty ? '' : '$keys\n');
    await temporary.rename(_keysFile.path);
  }

  static String _email(String email) {
    final value = email.trim().toLowerCase();
    if (!RegExp(r'^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$')
        .hasMatch(value)) {
      throw const FormatException('Expected an email address.');
    }
    return value;
  }
}
