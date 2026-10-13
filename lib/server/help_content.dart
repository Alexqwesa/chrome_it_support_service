import 'dart:convert';
import 'dart:io';

class HelpContent {
  HelpContent(this.directory);
  final String directory;
  final Map<String, Map<String, String>> _locales = {};

  Future<void> load() async {
    await for (final entry in Directory(directory).list()) {
      if (entry is! File || !entry.path.endsWith('.json')) continue;
      final code = entry.uri.pathSegments.last.replaceFirst(RegExp(r'\.json$'), '');
      if (!RegExp(r'^[a-z]{2,8}$').hasMatch(code)) continue;
      final file = entry;
      _locales[code] = (jsonDecode(await file.readAsString()) as Map)
          .cast<String, String>();
      for (final key in ['name', 'title', 'purpose', 'steps', 'warning',
        'existing', 'operator', 'download', 'sessions', 'signIn',
        'chromeHeading', 'operatorHeading', 'emailSubject', 'emailIntro',
        'emailExisting']) {
        if (_locales[code]![key]?.trim().isNotEmpty != true) {
          throw FormatException('Missing $key in ${file.path}');
        }
      }
    }
    for (final code in ['en', 'vi', 'ru']) {
      if (!_locales.containsKey(code)) {
        throw StateError('Missing required help locale: $code');
      }
    }
  }

  Map<String, String> locale(String? code) =>
      _locales[code] ?? _locales['vi']!;

  String emailSubject() => locale('vi')['emailSubject']!;

  String emailBody({required String helpUrl, required String downloadUrl,
      required bool existingChrome}) {
    return ['vi', 'ru', 'en', ..._locales.keys.where((code) =>
        !['vi', 'ru', 'en'].contains(code))].map((code) {
      final copy = locale(code);
      final intro = copy['emailIntro']!
          .replaceAll('{{helpUrl}}', helpUrl)
          .replaceAll('{{downloadUrl}}', downloadUrl);
      return '${copy['name']}\n$intro${existingChrome ? '\n${copy['emailExisting']}' : ''}';
    }).join('\n\n');
  }

  String page(String? code, String downloadUrl) {
    final selected = _locales.containsKey(code) ? code! : 'vi';
    final copy = locale(selected);
    String e(String value) => const HtmlEscape(HtmlEscapeMode.attribute).convert(value);
    final links = ['vi', 'ru', 'en', ..._locales.keys.where((lang) =>
        !['vi', 'ru', 'en'].contains(lang))]
        .map((lang) => '<a href="/help?lang=$lang">${e(locale(lang)['name']!)}</a>')
        .join(' | ');
    return '''<!doctype html><html lang="$selected"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${e(copy['title']!)}</title><style>
body{font:16px system-ui,sans-serif;max-width:850px;margin:2rem auto;padding:0 1rem;line-height:1.6;color:#202124}
.warn{background:#fff3d7;padding:1rem;border-radius:6px}a{color:#1456a0}
</style></head><body><nav>$links | <a href="/debug-sessions">${e(copy['sessions']!)}</a> | <a href="/admin/keys">${e(copy['signIn']!)}</a></nav>
<h1>${e(copy['title']!)}</h1><p>${e(copy['purpose']!)}</p><h2>1. ${e(copy['download']!)}</h2>
<p>${e(copy['steps']!)}</p><p><a href="${e(downloadUrl)}">${e(copy['download']!)}</a></p>
<h2>2. ${e(copy['chromeHeading']!)}</h2><p>${e(copy['existing']!)}</p><p class="warn">${e(copy['warning']!)}</p>
<h2>${e(copy['operatorHeading']!)}</h2><p>${e(copy['operator']!)}</p></body></html>''';
  }
}
