import 'dart:typed_data';

/// Minimal read-only ELF reader that lists the dynamic symbols a shared
/// object exports. It is used to check that a downloaded core library still
/// offers the JNI entry points the App links against before it is activated.
///
/// The reader only understands what a JNI library needs: the header, the
/// section table and the dynamic symbol table with its string table.
final class ElfDynamicSymbols {
  const ElfDynamicSymbols({required this.machine, required this.symbols});

  /// The `e_machine` value, for example 183 for AArch64.
  final int machine;

  /// Defined, globally visible symbols.
  final Set<String> symbols;

  bool contains(String name) => symbols.contains(name);
}

/// Raised when a file is not an ELF shared object this reader understands.
final class ElfFormatException implements Exception {
  const ElfFormatException(this.message);

  final String message;

  @override
  String toString() => 'ElfFormatException: $message';
}

const _elfMagic = [0x7f, 0x45, 0x4c, 0x46];
const _elfClass32 = 1;
const _elfClass64 = 2;
const _elfDataLittle = 1;
const _elfDataBig = 2;
const _sectionTypeDynsym = 11;
const _undefinedSection = 0;
const _bindGlobal = 1;
const _bindWeak = 2;
const _visibilityDefault = 0;

/// Parses the exported dynamic symbols of an ELF shared object.
///
/// Only defined symbols with global or weak binding and default visibility
/// are reported; undefined imports and local symbols are skipped.
ElfDynamicSymbols parseElfDynamicSymbols(List<int> bytes) {
  if (bytes.length < 64) {
    throw const ElfFormatException('The file is too short to be an ELF file');
  }
  final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  for (var index = 0; index < _elfMagic.length; index++) {
    if (data[index] != _elfMagic[index]) {
      throw const ElfFormatException('The file does not start with ELF magic');
    }
  }
  final elfClass = data[4];
  final elfData = data[5];
  if (elfClass != _elfClass32 && elfClass != _elfClass64) {
    throw const ElfFormatException('The ELF class is neither 32 nor 64 bit');
  }
  if (elfData != _elfDataLittle && elfData != _elfDataBig) {
    throw const ElfFormatException('The ELF byte order is unknown');
  }
  final reader = _Reader(
    data,
    bigEndian: elfData == _elfDataBig,
    is64Bit: elfClass == _elfClass64,
  );
  final machine = reader.u16(18);
  final sectionOffset = reader.u64or32(0x28);
  final sectionEntrySize = reader.u16(0x3a);
  final sectionCount = reader.u16(0x3c);
  if (sectionOffset == 0 || sectionCount == 0) {
    throw const ElfFormatException('The ELF file has no section table');
  }
  final sections = <_Section>[];
  for (var index = 0; index < sectionCount; index++) {
    final base = sectionOffset + index * sectionEntrySize;
    if (base + sectionEntrySize > data.length) {
      throw const ElfFormatException('The ELF section table is truncated');
    }
    sections.add(
      _Section(
        type: reader.u32(base + 4),
        offset: reader.u64or32(base + (reader.is64Bit ? 24 : 16)),
        size: reader.u64or32(base + (reader.is64Bit ? 32 : 20)),
        link: reader.u32(base + (reader.is64Bit ? 40 : 24)),
        entrySize: reader.u64or32(base + (reader.is64Bit ? 56 : 36)),
      ),
    );
  }
  final symbols = <String>{};
  for (final section in sections) {
    if (section.type != _sectionTypeDynsym || section.entrySize == 0) {
      continue;
    }
    if (section.link >= sections.length) {
      throw const ElfFormatException('The dynamic symbol table has no strings');
    }
    final strings = sections[section.link];
    final count = section.size ~/ section.entrySize;
    for (var index = 0; index < count; index++) {
      final base = section.offset + index * section.entrySize;
      if (base + section.entrySize > data.length) {
        throw const ElfFormatException('The dynamic symbol table is truncated');
      }
      final nameOffset = reader.u32(base);
      final info = data[base + 4];
      final other = data[base + 5];
      final sectionIndex = reader.u16(base + 6);
      final binding = info >> 4;
      final visibility = other & 0x3;
      if (sectionIndex == _undefinedSection) {
        continue;
      }
      if (binding != _bindGlobal && binding != _bindWeak) {
        continue;
      }
      if (visibility != _visibilityDefault) {
        continue;
      }
      final name = reader.string(strings.offset, nameOffset);
      if (name.isNotEmpty) {
        symbols.add(name);
      }
    }
  }
  return ElfDynamicSymbols(machine: machine, symbols: symbols);
}

final class _Section {
  const _Section({
    required this.type,
    required this.offset,
    required this.size,
    required this.link,
    required this.entrySize,
  });

  final int type;
  final int offset;
  final int size;
  final int link;
  final int entrySize;
}

final class _Reader {
  const _Reader(this.data, {required this.bigEndian, required this.is64Bit});

  final Uint8List data;
  final bool bigEndian;
  final bool is64Bit;

  int u16(int offset) {
    if (offset + 2 > data.length) {
      throw const ElfFormatException('The ELF file is truncated');
    }
    final first = data[offset];
    final second = data[offset + 1];
    return bigEndian ? (first << 8) | second : (second << 8) | first;
  }

  int u32(int offset) {
    if (offset + 4 > data.length) {
      throw const ElfFormatException('The ELF file is truncated');
    }
    var value = 0;
    for (var index = 0; index < 4; index++) {
      final byte = data[offset + index];
      value = bigEndian ? (value << 8) | byte : value | (byte << (8 * index));
    }
    return value;
  }

  int u64or32(int offset) => is64Bit ? u64(offset) : u32(offset);

  int u64(int offset) {
    if (offset + 8 > data.length) {
      throw const ElfFormatException('The ELF file is truncated');
    }
    var value = 0;
    for (var index = 0; index < 8; index++) {
      final byte = data[offset + index];
      value = bigEndian ? (value << 8) | byte : value | (byte << (8 * index));
    }
    return value;
  }

  String string(int tableOffset, int nameOffset) {
    if (tableOffset + nameOffset >= data.length) {
      throw const ElfFormatException('The ELF string table is truncated');
    }
    final end = tableOffset + nameOffset;
    var cursor = end;
    while (cursor < data.length && data[cursor] != 0) {
      cursor++;
    }
    return String.fromCharCodes(data.sublist(end, cursor));
  }
}
