import 'package:onexray/core/system_proxy/system_proxy_models.dart';

/// Parses the GVariant text that `gsettings get` prints for a string array,
/// for example `['localhost', '127.0.0.1']` or the untitled empty form
/// `@as []`.
List<String> parseGVariantStrings(String text) {
  var body = text.trim();
  final prefix = RegExp(r'^@[A-Za-z0-9.]+\s+');
  if (prefix.hasMatch(body)) body = body.replaceFirst(prefix, '').trim();
  if (!body.startsWith('[') || !body.endsWith(']')) {
    throw SystemProxyFailure('Unexpected GVariant string list: $text');
  }
  final inner = body.substring(1, body.length - 1).trim();
  if (inner.isEmpty) return const [];
  final values = <String>[];
  final current = StringBuffer();
  var quoted = false;
  var escaped = false;
  for (final unit in inner.codeUnits) {
    final character = String.fromCharCode(unit);
    if (escaped) {
      current.write(character);
      escaped = false;
      continue;
    }
    if (quoted && character == r'\') {
      escaped = true;
      continue;
    }
    if (character == "'") {
      quoted = !quoted;
      continue;
    }
    if (!quoted) {
      if (character == ',') {
        values.add(current.toString());
        current.clear();
        continue;
      }
      if (character.trim().isEmpty) continue;
      throw SystemProxyFailure('Unexpected GVariant string list: $text');
    }
    current.write(character);
  }
  if (quoted || escaped) {
    throw SystemProxyFailure('Unexpected GVariant string list: $text');
  }
  values.add(current.toString());
  return values;
}

/// Formats a string array the way `gsettings set` expects GVariant text:
/// single-quoted entries separated by `, `; an empty list becomes `[]`.
String formatGVariantStrings(List<String> values) {
  if (values.isEmpty) return '[]';
  final entries = values
      .map(
        (value) =>
            "'${value.replaceAll(r'\', r'\\').replaceAll("'", r"\'")}'",
      )
      .join(', ');
  return '[$entries]';
}
