import 'dart:io';

import 'package:onexray/core/errors/failure.dart';
import 'package:onexray/service/advanced/xray/core_version/storage.dart';
import 'package:path/path.dart' as p;

/// The process name Linux and Windows use to discover a running core
/// (`pgrep -x OneXrayCore`, the Windows Core process watch). A downloaded
/// archive extracts as `xray`/`xray.exe`, so it must never be launched under
/// that name; it runs from the canonical path prepared here instead.
const coreExecutableName = 'OneXrayCore';

/// The name the release archive carries the core binary under.
String get _coreBinaryName => Platform.isWindows ? 'xray.exe' : 'xray';

String get _coreExecutableName =>
    Platform.isWindows ? '$coreExecutableName.exe' : coreExecutableName;

/// Publishes the extracted binary of one installed version beside its source
/// under the canonical core name and returns that path. The copy is atomic
/// (temporary file plus rename) and executable; a repeated call with an
/// unchanged source is a no-op. Returns null when the version or its binary
/// is gone, so callers fall back to the bundled core.
Future<String?> prepareCoreExecutable(
  String installationId, {
  Future<CoreVersionStorage> Function()? openStorage,
}) async {
  final storage = await (openStorage ?? CoreVersionStorage.open)();
  final manifest = await storage.readManifest(installationId);
  if (manifest == null) {
    return null;
  }
  final rootName = manifest.assetName.endsWith('.zip')
      ? manifest.assetName.substring(
          0,
          manifest.assetName.length - '.zip'.length,
        )
      : manifest.assetName;
  final source = File(p.join(manifest.installDir, rootName, _coreBinaryName));
  if (!await source.exists()) {
    return null;
  }
  final target = File(
    p.join(p.dirname(p.dirname(source.path)), _coreExecutableName),
  );
  try {
    if (!await target.exists() ||
        await target.length() != await source.length()) {
      final temporary = File('${target.path}.tmp');
      await source.copy(temporary.path);
      if (!Platform.isWindows) {
        // Downloads arrive without the mode bits of the packaged binary.
        final result = await Process.run('chmod', ['0755', temporary.path]);
        if (result.exitCode != 0) {
          throw ProcessException(
            'chmod',
            ['0755', temporary.path],
            'Preparing the core executable failed',
            result.exitCode,
          );
        }
      }
      if (await target.exists()) {
        await target.delete();
      }
      await temporary.rename(target.path);
    }
  } on FileSystemException catch (error) {
    throw AppFailure(FailureCategory.storage, 'coreVersionIo', cause: error);
  }
  return target.path;
}
