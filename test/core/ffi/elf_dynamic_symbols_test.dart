import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:onexray/core/ffi/elf_dynamic_symbols.dart';
import 'package:onexray/core/model/core_library_compatibility.dart';
import 'package:onexray/core/tools/core_platform.dart';

/// Builds a small but valid ELF64 shared object that exports [symbols].
Uint8List buildElf({
  int machine = 183,
  List<String> symbols = const [],
  List<String> localSymbols = const [],
  List<String> undefinedSymbols = const [],
  List<String> hiddenSymbols = const [],
}) {
  final names = <String>[
    '',
    ...symbols,
    ...localSymbols,
    ...undefinedSymbols,
    ...hiddenSymbols,
  ];
  final stringTable = <int>[];
  final nameOffsets = <int>[];
  for (final name in names) {
    nameOffsets.add(stringTable.length);
    stringTable.addAll(name.codeUnits);
    stringTable.add(0);
  }
  final symbolCount =
      1 +
      symbols.length +
      localSymbols.length +
      undefinedSymbols.length +
      hiddenSymbols.length;
  final headerSize = 64;
  final sectionSize = 64;
  final sectionCount = 3;
  final sectionOffset = headerSize;
  final symbolOffset = sectionOffset + sectionCount * sectionSize;
  final symbolTableSize = symbolCount * 24;
  final stringOffset = symbolOffset + symbolTableSize;

  final bytes = Uint8List(stringOffset + stringTable.length);
  final data = ByteData.sublistView(bytes);
  bytes.setRange(0, 4, const [0x7f, 0x45, 0x4c, 0x46]);
  bytes[4] = 2; // ELFCLASS64
  bytes[5] = 1; // ELFDATA2LSB
  bytes[6] = 1; // EV_CURRENT
  data.setUint16(16, 3, Endian.little); // ET_DYN
  data.setUint16(18, machine, Endian.little);
  data.setUint32(20, 1, Endian.little);
  data.setUint64(0x28, sectionOffset, Endian.little);
  data.setUint16(0x34, 64, Endian.little); // e_ehsize
  data.setUint16(0x3a, sectionSize, Endian.little);
  data.setUint16(0x3c, sectionCount, Endian.little);
  data.setUint16(0x3e, 0, Endian.little);

  void writeSection(
    int index, {
    required int type,
    required int offset,
    required int size,
    required int link,
    required int entrySize,
  }) {
    final base = sectionOffset + index * sectionSize;
    data.setUint32(base + 4, type, Endian.little);
    data.setUint64(base + 24, offset, Endian.little);
    data.setUint64(base + 32, size, Endian.little);
    data.setUint32(base + 40, link, Endian.little);
    data.setUint64(base + 56, entrySize, Endian.little);
  }

  writeSection(
    1,
    type: 11,
    offset: symbolOffset,
    size: symbolTableSize,
    link: 2,
    entrySize: 24,
  );
  writeSection(
    2,
    type: 3,
    offset: stringOffset,
    size: stringTable.length,
    link: 0,
    entrySize: 0,
  );
  bytes.setRange(stringOffset, stringOffset + stringTable.length, stringTable);

  var slot = 0;
  void writeSymbol(
    int nameOffset, {
    required int binding,
    required int visibility,
    required int sectionIndex,
  }) {
    final base = symbolOffset + slot * 24;
    data.setUint32(base, nameOffset, Endian.little);
    data.setUint8(base + 4, (binding << 4) | 0);
    data.setUint8(base + 5, visibility);
    data.setUint16(base + 6, sectionIndex, Endian.little);
    slot++;
  }

  writeSymbol(nameOffsets[0], binding: 0, visibility: 0, sectionIndex: 0);
  for (var index = 0; index < symbols.length; index++) {
    writeSymbol(
      nameOffsets[1 + index],
      binding: 1,
      visibility: 0,
      sectionIndex: 1,
    );
  }
  for (var index = 0; index < localSymbols.length; index++) {
    writeSymbol(
      nameOffsets[1 + symbols.length + index],
      binding: 0,
      visibility: 0,
      sectionIndex: 1,
    );
  }
  for (var index = 0; index < undefinedSymbols.length; index++) {
    writeSymbol(
      nameOffsets[1 + symbols.length + localSymbols.length + index],
      binding: 1,
      visibility: 0,
      sectionIndex: 0,
    );
  }
  for (var index = 0; index < hiddenSymbols.length; index++) {
    writeSymbol(
      nameOffsets[1 +
          symbols.length +
          localSymbols.length +
          undefinedSymbols.length +
          index],
      binding: 1,
      visibility: 2,
      sectionIndex: 1,
    );
  }
  return bytes;
}

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
