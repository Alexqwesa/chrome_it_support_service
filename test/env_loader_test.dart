import 'dart:io';

import 'package:chrome_it_support_service/env_loader.dart';
import 'package:test/test.dart';

void main() {
  test('.env.example, .env, and process env merge in order', () async {
    final directory = await Directory.systemTemp.createTemp('env-loader-test-');
    addTearDown(() => directory.delete(recursive: true));

    final example = File('${directory.path}/.env.example');
    final env = File('${directory.path}/.env');
    await example.writeAsString('''
VALUE=from-example
EXAMPLE_ONLY=yes
QUOTED="hello world"
''');
    await env.writeAsString('''
VALUE=from-env
ENV_ONLY=yes
''');

    final merged = await loadMergedEnvironment(
      files: <String>[example.path, env.path],
      processEnvironment: <String, String>{'VALUE': 'from-process'},
    );

    expect(merged['VALUE'], 'from-process');
    expect(merged['EXAMPLE_ONLY'], 'yes');
    expect(merged['ENV_ONLY'], 'yes');
    expect(merged['QUOTED'], 'hello world');
  });
}
