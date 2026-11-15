import 'package:flutter_test/flutter_test.dart';
import 'package:onexray/core/system_proxy/system_proxy_models.dart';
import 'package:onexray/core/system_proxy/windows_registry_ffi.dart';

void main() {
  test('the pinned Win32 constants match the documented values', () {
    expect(hkeyCurrentUser, 0x80000001);
    expect(keyRead, 0x20019); // KEY_READ
    expect(keySetValue, 0x2); // KEY_SET_VALUE
    expect(regSz, 1);
    expect(regDword, 4);
    expect(errorSuccess, 0);
    expect(errorFileNotFound, 2);
    expect(errorMoreData, 234);
    expect(internetOptionSettingsChanged, 39);
    expect(internetOptionRefresh, 37);
    expect(
      internetSettingsPath,
      r'Software\Microsoft\Windows\CurrentVersion\Internet Settings',
    );
  });

  test('REG_SZ length counts every UTF-16 unit plus the null terminator', () {
    expect(utf16ByteLength(''), 2);
    expect(utf16ByteLength('1'), 4);
    expect(utf16ByteLength('127.0.0.1:10808'), 2 * (15 + 1));
    // A supplementary character occupies two UTF-16 code units.
    expect(utf16ByteLength('a\u{1F600}'), 2 * (3 + 1));
  });

  test('REG_SZ text decodes little-endian UTF-16 up to the first null', () {
    // 'a:1' followed by the terminator.
    expect(
      decodeRegistryText([0x61, 0, 0x3A, 0, 0x31, 0, 0, 0]),
      'a:1',
    );
    expect(decodeRegistryText([0, 0]), isEmpty);
    expect(decodeRegistryText(const []), isEmpty);
    expect(decodeRegistryText([0x69, 0x27, 0, 0]), '\u2769');
  });

  test('REG_DWORD decodes little-endian and rejects short values', () {
    expect(decodeRegistryDword([1, 0, 0, 0]), 1);
    expect(decodeRegistryDword([0x38, 0x2A, 0, 0]), 10808);
    expect(decodeRegistryDword([0xFF, 0xFF, 0xFF, 0xFF]), 0xFFFFFFFF);
    expect(
      () => decodeRegistryDword([1, 0, 0]),
      throwsA(isA<SystemProxyFailure>()),
    );
  });
}
