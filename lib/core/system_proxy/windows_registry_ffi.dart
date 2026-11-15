import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:onexray/core/system_proxy/system_proxy_models.dart';
import 'package:onexray/core/system_proxy/windows_registry.dart';

// Win32 constants used below, public so tests pin the documented values.
const hkeyCurrentUser = 0x80000001;
const internetSettingsPath =
    r'Software\Microsoft\Windows\CurrentVersion\Internet Settings';
const keyRead = 0x20019; // KEY_READ
const keySetValue = 0x2; // KEY_SET_VALUE
const regSz = 1;
const regDword = 4;
const errorSuccess = 0;
const errorFileNotFound = 2;
const errorMoreData = 234;
const internetOptionSettingsChanged = 39;
const internetOptionRefresh = 37;

/// Registry byte length of a `REG_SZ` write: every UTF-16 code unit plus the
/// null terminator WinINet expects, two bytes each.
int utf16ByteLength(String value) => (value.length + 1) * 2;

/// Little-endian UTF-16 text of a `REG_SZ` value, ending at the first null
/// code unit like `Pointer<Utf16>.toDartString` does.
String decodeRegistryText(List<int> bytes) {
  final units = <int>[];
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    final unit = bytes[i] | (bytes[i + 1] << 8);
    if (unit == 0) break;
    units.add(unit);
  }
  return String.fromCharCodes(units);
}

/// Little-endian `REG_DWORD` number from at least four value bytes.
int decodeRegistryDword(List<int> bytes) {
  if (bytes.length < 4) {
    throw const SystemProxyFailure('REG_DWORD is too small');
  }
  return bytes[0] | (bytes[1] << 8) | (bytes[2] << 16) | (bytes[3] << 24);
}

typedef _RegOpenKeyExWNative =
    Int32 Function(
      IntPtr key,
      Pointer<Utf16> subKey,
      Uint32 options,
      Uint32 access,
      Pointer<IntPtr> result,
    );
typedef _RegOpenKeyExW =
    int Function(
      int key,
      Pointer<Utf16> subKey,
      int options,
      int access,
      Pointer<IntPtr> result,
    );

typedef _RegQueryValueExWNative =
    Int32 Function(
      IntPtr key,
      Pointer<Utf16> name,
      Pointer<Uint32> reserved,
      Pointer<Uint32> type,
      Pointer<Uint8> data,
      Pointer<Uint32> byteCount,
    );
typedef _RegQueryValueExW =
    int Function(
      int key,
      Pointer<Utf16> name,
      Pointer<Uint32> reserved,
      Pointer<Uint32> type,
      Pointer<Uint8> data,
      Pointer<Uint32> byteCount,
    );

typedef _RegSetValueExWNative =
    Int32 Function(
      IntPtr key,
      Pointer<Utf16> name,
      Uint32 reserved,
      Uint32 type,
      Pointer<Uint8> data,
      Uint32 byteCount,
    );
typedef _RegSetValueExW =
    int Function(
      int key,
      Pointer<Utf16> name,
      int reserved,
      int type,
      Pointer<Uint8> data,
      int byteCount,
    );

typedef _RegDeleteValueWNative = Int32 Function(IntPtr key, Pointer<Utf16> name);
typedef _RegDeleteValueW = int Function(int key, Pointer<Utf16> name);

typedef _RegCloseKeyNative = Int32 Function(IntPtr key);
typedef _RegCloseKey = int Function(int key);

typedef _InternetSetOptionWNative =
    Int32 Function(IntPtr connection, Uint32 option, Pointer<Void> buffer, Uint32 length);
typedef _InternetSetOptionW =
    int Function(int connection, int option, Pointer<Void> buffer, int length);

/// Win32 implementation over advapi32.dll and wininet.dll. The libraries are
/// opened only when this class is constructed, which the backend factory does
/// on Windows only.
final class WindowsRegistryFfi implements WindowsRegistryAccess {
  WindowsRegistryFfi()
    : _advapi32 = DynamicLibrary.open('advapi32.dll'),
      _wininet = DynamicLibrary.open('wininet.dll') {
    _openKey = _advapi32.lookupFunction<_RegOpenKeyExWNative, _RegOpenKeyExW>(
      'RegOpenKeyExW',
    );
    _queryValue = _advapi32
        .lookupFunction<_RegQueryValueExWNative, _RegQueryValueExW>(
          'RegQueryValueExW',
        );
    _setValue = _advapi32
        .lookupFunction<_RegSetValueExWNative, _RegSetValueExW>(
          'RegSetValueExW',
        );
    _deleteValue = _advapi32
        .lookupFunction<_RegDeleteValueWNative, _RegDeleteValueW>(
          'RegDeleteValueW',
        );
    _closeKey = _advapi32.lookupFunction<_RegCloseKeyNative, _RegCloseKey>(
      'RegCloseKey',
    );
    _setOption = _wininet
        .lookupFunction<_InternetSetOptionWNative, _InternetSetOptionW>(
          'InternetSetOptionW',
        );
  }

  final DynamicLibrary _advapi32;
  final DynamicLibrary _wininet;

  late final _RegOpenKeyExW _openKey;
  late final _RegQueryValueExW _queryValue;
  late final _RegSetValueExW _setValue;
  late final _RegDeleteValueW _deleteValue;
  late final _RegCloseKey _closeKey;
  late final _InternetSetOptionW _setOption;

  @override
  RegistryValue? readValue(String name) {
    final key = _open(keyRead);
    final namePointer = name.toNativeUtf16();
    final type = calloc<Uint32>();
    final byteCount = calloc<Uint32>();
    try {
      byteCount.value = 0;
      var status = _queryValue(
        key,
        namePointer,
        nullptr,
        type,
        nullptr,
        byteCount,
      );
      if (status == errorFileNotFound) return null;
      if (status != errorMoreData && status != errorSuccess) {
        throw SystemProxyFailure(
          'RegQueryValueExW $name failed with status $status',
        );
      }
      if (byteCount.value == 0) {
        return (text: type.value == regSz ? '' : null, number: null);
      }
      final buffer = calloc<Uint8>(byteCount.value);
      try {
        status = _queryValue(
          key,
          namePointer,
          nullptr,
          type,
          buffer,
          byteCount,
        );
        if (status == errorFileNotFound) return null;
        if (status != errorSuccess) {
          throw SystemProxyFailure(
            'RegQueryValueExW $name failed with status $status',
          );
        }
        final bytes = buffer.asTypedList(byteCount.value);
        if (type.value == regDword) {
          return (text: null, number: decodeRegistryDword(bytes));
        }
        if (type.value == regSz) {
          return (text: decodeRegistryText(bytes), number: null);
        }
        throw SystemProxyFailure(
          'Unexpected registry type ${type.value} for $name',
        );
      } finally {
        calloc.free(buffer);
      }
    } finally {
      calloc.free(byteCount);
      calloc.free(type);
      calloc.free(namePointer);
      _closeKey(key);
    }
  }

  @override
  void setStringValue(String name, String value) {
    final key = _open(keySetValue);
    final namePointer = name.toNativeUtf16();
    // REG_SZ is written with its null terminator, as WinINet expects.
    final text = value.toNativeUtf16();
    try {
      final status = _setValue(
        key,
        namePointer,
        0,
        regSz,
        text.cast(),
        utf16ByteLength(value),
      );
      if (status != errorSuccess) {
        throw SystemProxyFailure(
          'RegSetValueExW $name failed with status $status',
        );
      }
    } finally {
      calloc.free(text);
      calloc.free(namePointer);
      _closeKey(key);
    }
  }

  @override
  void setDwordValue(String name, int value) {
    final key = _open(keySetValue);
    final namePointer = name.toNativeUtf16();
    final number = calloc<Uint32>();
    number.value = value;
    try {
      final status = _setValue(
        key,
        namePointer,
        0,
        regDword,
        number.cast(),
        4,
      );
      if (status != errorSuccess) {
        throw SystemProxyFailure(
          'RegSetValueExW $name failed with status $status',
        );
      }
    } finally {
      calloc.free(number);
      calloc.free(namePointer);
      _closeKey(key);
    }
  }

  @override
  void deleteValue(String name) {
    final key = _open(keySetValue);
    final namePointer = name.toNativeUtf16();
    try {
      final status = _deleteValue(key, namePointer);
      if (status != errorSuccess && status != errorFileNotFound) {
        throw SystemProxyFailure(
          'RegDeleteValue $name failed with status $status',
        );
      }
    } finally {
      calloc.free(namePointer);
      _closeKey(key);
    }
  }

  @override
  void notifySettingsChanged() {
    // Best effort: running processes pick the registry change up on notice.
    _setOption(0, internetOptionSettingsChanged, nullptr, 0);
    _setOption(0, internetOptionRefresh, nullptr, 0);
  }

  @override
  void close() {
    // Handles are opened and closed per operation.
  }

  int _open(int access) {
    final subKey = internetSettingsPath.toNativeUtf16();
    final result = calloc<IntPtr>();
    try {
      final status = _openKey(hkeyCurrentUser, subKey, 0, access, result);
      if (status != errorSuccess) {
        throw SystemProxyFailure('RegOpenKeyExW failed with status $status');
      }
      return result.value;
    } finally {
      calloc.free(result);
      calloc.free(subKey);
    }
  }
}
