import 'package:flutter_test/flutter_test.dart';
import 'package:onexray/core/system_proxy/gvariant.dart';
import 'package:onexray/core/system_proxy/system_proxy_models.dart';

void main() {
  test('parses the quoted list form printed by gsettings get', () {
    expect(
      parseGVariantStrings("['localhost', '127.0.0.1', '::1']"),
      ['localhost', '127.0.0.1', '::1'],
    );
  });

  test('parses the typed empty list and typed content', () {
    expect(parseGVariantStrings('@as []'), isEmpty);
    expect(parseGVariantStrings("@as ['corp']"), ['corp']);
  });

  test('parses empty strings and escaped quotes or backslashes', () {
    expect(parseGVariantStrings(r"['', 'it\'s', 'back\\slash']"), [
      '',
      "it's",
      r'back\slash',
    ]);
  });

  test('formats the GVariant text gsettings set expects', () {
    expect(formatGVariantStrings(const []), '[]');
    expect(
      formatGVariantStrings(const ['localhost', '127.0.0.1', '::1']),
      "['localhost', '127.0.0.1', '::1']",
    );
    expect(formatGVariantStrings(const ["it's", r'back\slash']),
        r"['it\'s', 'back\\slash']");
  });

  test('round-trips user tokens through parse and format', () {
    final values = ['', "quote'", 'plain , comma', r'\ slash'];
    expect(parseGVariantStrings(formatGVariantStrings(values)), values);
  });

  test('rejects text that is not a string list', () {
    for (final invalid in ['', 'none', "['unbalanced"]) {
      expect(
        () => parseGVariantStrings(invalid),
        throwsA(isA<SystemProxyFailure>()),
        reason: invalid,
      );
    }
  });
}
