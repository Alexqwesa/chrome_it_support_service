import 'dart:io';

Future<Map<String, String>> loadMergedEnvironment({
  Map<String, String> defaults = const <String, String>{},
  String defaultSource = 'compiled defaults',
  List<String> files = const <String>['.env.example', '.env'],
  Map<String, String>? processEnvironment,
}) async {
  return (await loadMergedEnvironmentWithSources(
    defaults: defaults,
    defaultSource: defaultSource,
    files: files,
    processEnvironment: processEnvironment,
  ))
      .values;
}

class LoadedEnvironment {
  const LoadedEnvironment(this.values, this.sources);

  final Map<String, String> values;
  final Map<String, String> sources;
}

Future<LoadedEnvironment> loadMergedEnvironmentWithSources({
  Map<String, String> defaults = const <String, String>{},
  String defaultSource = 'compiled defaults',
  List<String> files = const <String>['.env.example', '.env'],
  Map<String, String>? processEnvironment,
}) async {
  final merged = <String, String>{...defaults};
  final sources = <String, String>{
    for (final key in defaults.keys) key: defaultSource,
  };
  for (final path in files) {
    final file = File(path);
    if (await file.exists()) {
      final parsed = _parseDotEnv(await file.readAsLines());
      merged.addAll(parsed);
      for (final key in parsed.keys) {
        sources[key] = path;
      }
    }
  }
  final process = processEnvironment ?? Platform.environment;
  merged.addAll(process);
  for (final key in process.keys) {
    sources[key] = 'process environment';
  }
  return LoadedEnvironment(merged, sources);
}

Map<String, String> _parseDotEnv(List<String> lines) {
  final values = <String, String>{};
  for (final rawLine in lines) {
    var line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    if (line.startsWith('export ')) {
      line = line.substring('export '.length).trimLeft();
    }
    final separator = line.indexOf('=');
    if (separator <= 0) continue;
    final key = line.substring(0, separator).trim();
    if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(key)) continue;
    values[key] = _parseValue(line.substring(separator + 1).trim());
  }
  return values;
}

String _parseValue(String rawValue) {
  if (rawValue.length >= 2) {
    final first = rawValue.codeUnitAt(0);
    final last = rawValue.codeUnitAt(rawValue.length - 1);
    if (first == last && (first == 34 || first == 39)) {
      final inner = rawValue.substring(1, rawValue.length - 1);
      return first == 34 ? _unescapeDoubleQuoted(inner) : inner;
    }
  }
  final commentStart = rawValue.indexOf(' #');
  return (commentStart == -1 ? rawValue : rawValue.substring(0, commentStart))
      .trimRight();
}

String _unescapeDoubleQuoted(String value) {
  return value
      .replaceAll(r'\n', '\n')
      .replaceAll(r'\r', '\r')
      .replaceAll(r'\t', '\t')
      .replaceAll(r'\"', '"')
      .replaceAll(r'\\', r'\');
}
