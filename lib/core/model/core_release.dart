import 'package:onexray/core/errors/failure.dart';

/// CalVer tags like v26.11.9 (YY.M.D). Go mirror tags such as v1.261109.0
/// never match, so they can never enter the core version catalog.
final _coreCatalogTagPattern = RegExp(r'^v(\d{2})\.(\d{1,2})\.(\d{1,2})$');

/// One GitHub release asset, kept in the shape the GitHub API publishes so
/// catalog caches round-trip without a private schema.
final class CoreAsset {
  final int id;
  final String name;
  final int size;

  /// GitHub's asset digest in `sha256:<hex>` form, or null when absent.
  final String? digest;
  final String downloadUrl;

  const CoreAsset({
    required this.id,
    required this.name,
    required this.size,
    this.digest,
    required this.downloadUrl,
  });

  static final _sha256DigestPattern = RegExp(r'^sha256:([0-9a-fA-F]{64})$');

  /// Pure lowercase hex of the SHA-256 digest, or null when the digest is
  /// missing or uses another algorithm.
  String? get sha256Hex {
    final value = digest;
    if (value == null) {
      return null;
    }
    return _sha256DigestPattern.firstMatch(value)?.group(1)?.toLowerCase();
  }

  /// Parses one GitHub asset. Assets without a usable SHA-256 digest are
  /// dropped instead of being offered for unverified installation; assets
  /// whose required fields are not the documented types are bad input.
  static CoreAsset? tryParse(Object? json) {
    if (json is! Map) {
      throw const AppFailure(
        FailureCategory.input,
        'coreReleaseAsset',
        cause: 'GitHub release asset is not an object',
      );
    }
    final id = json['id'];
    final name = json['name'];
    final size = json['size'];
    final downloadUrl = json['browser_download_url'];
    if (id is! int ||
        name is! String ||
        name.isEmpty ||
        size is! int ||
        size < 0 ||
        downloadUrl is! String ||
        downloadUrl.isEmpty) {
      throw const AppFailure(
        FailureCategory.input,
        'coreReleaseAsset',
        cause: 'GitHub release asset fields are invalid',
      );
    }
    final digest = json['digest'];
    final asset = CoreAsset(
      id: id,
      name: name,
      size: size,
      digest: digest is String ? digest : null,
      downloadUrl: downloadUrl,
    );
    if (asset.sha256Hex == null) {
      return null;
    }
    return asset;
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'size': size,
    if (digest != null) 'digest': digest,
    'browser_download_url': downloadUrl,
  };
}

/// One libXray GitHub release. Prerelease is preserved, not dropped: the
/// libXray release workflow publishes prereleases that maintainers later
/// promote to normal releases.
final class CoreRelease {
  final String tag;
  final DateTime publishedAt;
  final bool prerelease;
  final List<CoreAsset> assets;

  CoreRelease({
    required this.tag,
    required this.publishedAt,
    required this.prerelease,
    required List<CoreAsset> assets,
  }) : assets = List.unmodifiable(assets);

  CoreAsset? assetNamed(String name) {
    for (final asset in assets) {
      if (asset.name == name) {
        return asset;
      }
    }
    return null;
  }

  /// Only plausible CalVer YY.M.D tags enter the catalog. Go mirror tags and
  /// any other tag shape are rejected.
  static bool isCatalogTag(String tag) {
    final match = _coreCatalogTagPattern.firstMatch(tag);
    if (match == null) {
      return false;
    }
    final year = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    final day = int.parse(match.group(3)!);
    return year >= 24 && month >= 1 && month <= 12 && day >= 1 && day <= 31;
  }

  /// Parses one release from the GitHub releases API. Malformed fields fail
  /// as input errors; assets without a SHA-256 digest are dropped.
  static CoreRelease fromJson(Map<String, dynamic> json) {
    final tag = json['tag_name'];
    if (tag is! String || tag.isEmpty) {
      throw const AppFailure(
        FailureCategory.input,
        'coreRelease',
        cause: 'GitHub release has no tag_name',
      );
    }
    final publishedAt = json['published_at'];
    if (publishedAt is! String) {
      throw AppFailure(
        FailureCategory.input,
        'coreRelease',
        cause: 'GitHub release $tag has no published_at',
      );
    }
    final published = DateTime.tryParse(publishedAt);
    if (published == null) {
      throw AppFailure(
        FailureCategory.input,
        'coreRelease',
        cause: 'GitHub release $tag has an unreadable published_at',
      );
    }
    final prerelease = json['prerelease'];
    if (prerelease is! bool) {
      throw AppFailure(
        FailureCategory.input,
        'coreRelease',
        cause: 'GitHub release $tag has no prerelease flag',
      );
    }
    final assets = <CoreAsset>[];
    final rawAssets = json['assets'];
    if (rawAssets != null) {
      if (rawAssets is! List) {
        throw AppFailure(
          FailureCategory.input,
          'coreRelease',
          cause: 'GitHub release $tag has a non-list assets field',
        );
      }
      for (final entry in rawAssets) {
        final asset = CoreAsset.tryParse(entry);
        if (asset != null) {
          assets.add(asset);
        }
      }
    }
    return CoreRelease(
      tag: tag,
      publishedAt: published.toUtc(),
      prerelease: prerelease,
      assets: assets,
    );
  }

  Map<String, Object?> toJson() => {
    'tag_name': tag,
    'published_at': publishedAt.toIso8601String(),
    'prerelease': prerelease,
    'assets': [for (final asset in assets) asset.toJson()],
  };
}
