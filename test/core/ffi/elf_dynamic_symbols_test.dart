import 'package:flutter_test/flutter_test.dart';
import 'package:onexray/core/ffi/elf_dynamic_symbols.dart';
import 'package:onexray/core/model/core_library_compatibility.dart';
import 'package:onexray/core/tools/core_platform.dart';
import '../../support/elf_fixture.dart';

void main() {
  group('parseElfDynamicSymbols', () {
    test('lists defined global symbols only', () {
      final bytes = buildElf(
        symbols: const ['Java_libXray_LibXray_invoke'],
        localSymbols: const ['local_only'],
        undefinedSymbols: const ['imported_only'],
        hiddenSymbols: const ['hidden_only'],
      );
      final parsed = parseElfDynamicSymbols(bytes);
      expect(parsed.machine, 183);
      expect(parsed.symbols, contains('Java_libXray_LibXray_invoke'));
      expect(parsed.symbols, isNot(contains('local_only')));
      expect(parsed.symbols, isNot(contains('imported_only')));
      expect(parsed.symbols, isNot(contains('hidden_only')));
    });

    test('rejects a file without ELF magic', () {
      expect(
        () => parseElfDynamicSymbols(List<int>.filled(128, 7)),
        throwsA(isA<ElfFormatException>()),
      );
    });

    test('rejects a truncated file', () {
      expect(
        () => parseElfDynamicSymbols(List<int>.filled(10, 0)),
        throwsA(isA<ElfFormatException>()),
      );
    });
  });

  group('checkCoreLibrary', () {
    test('accepts a library that exports every required entry', () {
      final bytes = buildElf(symbols: coreLibraryRequiredSymbols);
      final check = checkCoreLibrary(
        bytes,
        platform: CorePlatform.android,
        abi: CoreAbi.arm64,
      );
      expect(check.compatibility, CoreLibraryCompatibility.compatible);
      expect(check.missingSymbols, isEmpty);
      expect(check.machine, 183);
    });

    test('warns when an entry point is missing', () {
      final bytes = buildElf(
        symbols: coreLibraryRequiredSymbols
            .where((symbol) => symbol != 'Java_libXray_LibXray_setDNS')
            .toList(),
      );
      final check = checkCoreLibrary(
        bytes,
        platform: CorePlatform.android,
        abi: CoreAbi.arm64,
      );
      expect(check.compatibility, CoreLibraryCompatibility.warning);
      expect(check.missingSymbols, ['Java_libXray_LibXray_setDNS']);
      expect(check.isUsable, isTrue);
    });

    test('refuses a library built for another CPU', () {
      final bytes = buildElf(symbols: coreLibraryRequiredSymbols, machine: 62);
      final check = checkCoreLibrary(
        bytes,
        platform: CorePlatform.android,
        abi: CoreAbi.arm64,
      );
      expect(check.compatibility, CoreLibraryCompatibility.fatal);
      expect(check.isUsable, isFalse);
      expect(check.reason, contains('62'));
    });

    test('refuses a file that is not a shared object', () {
      final check = checkCoreLibrary(
        List<int>.filled(128, 3),
        platform: CorePlatform.android,
        abi: CoreAbi.arm64,
      );
      expect(check.compatibility, CoreLibraryCompatibility.fatal);
      expect(check.isUsable, isFalse);
    });
  });

  test('android library entries follow the released archive layout', () {
    expect(
      coreLibraryEntry(CorePlatform.android, CoreAbi.arm64),
      'jni/arm64-v8a/libgojni.so',
    );
    expect(
      coreLibraryEntry(CorePlatform.android, CoreAbi.x64),
      'jni/x86_64/libgojni.so',
    );
    expect(coreLibraryMachine(CorePlatform.android, CoreAbi.arm64), 183);
    expect(coreLibraryMachine(CorePlatform.android, CoreAbi.x64), 62);
    expect(coreLibraryEntry(CorePlatform.linux, CoreAbi.arm64), isNull);
  });
}
