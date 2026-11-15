import 'dart:convert';
import 'dart:io';

import 'package:onexray/core/errors/failure.dart';
import 'package:onexray/core/model/core_release.dart';
import 'package:onexray/core/network/client.dart';
import 'package:onexray/core/tools/core_platform.dart';
import 'package:onexray/service/advanced/xray/core_version/storage.dart';

/// Status line, ETag header and body of one catalog request, kept flat so
/// tests can answer without a full [HttpClient].
typedef CoreCatalogResponse = ({int statusCode, String? etag, String body});

/// Performs the catalog HTTP exchange. Transport failures propagate raw;
/// every HTTP status arrives as a [CoreCatalogResponse].
typedef CoreCatalogRequest = Future<CoreCatalogResponse> Function(
  Uri uri,
  Map<String, String> headers,
);

/// One catalog read. [fromCache] reports the data came from disk; [stale]
/// reports the network failed and the cache was served offline.
final class CoreCatalogResult {
  final List<CoreRelease> releases;
  final DateTime fetchedAt;
  final bool fromCache;
  final bool stale;

  const CoreCatalogResult({
    required this.releases,
    required this.fetchedAt,
    required this.fromCache,
    required this.stale,
  });
}

final class _CatalogCache {
  final String? etag;
  final DateTime fetchedAt;
  final List<CoreRelease> releases;

  const _CatalogCache({
    required this.etag,
    required this.fetchedAt,
    required this.releases,
  });
}

/// Reads the libXray release catalog from GitHub and keeps it in
/// core/catalog.json with an ETag and a 24 hour time-to-live.
final class CoreCatalog {
  static final releasesUri = Uri.parse(
    'https://api.github.com/repos/XTLS/libXray/releases?per_page=100',
  );
  static const cacheTtl = Duration(hours: 24);

  /// GitHub reports rate limits and abuse detection as 403/429; the response
  /// body carries the reset information shown to the user.
  static const _rateLimitStatuses = {403, 429};
  static const _maxBodyBytes = 8 * 1024 * 1024;
  static const _maxRedirects = 5;

  final CoreVersionStorage storage;

  /// Release asset the catalog is filtered to, or null when the current
  /// platform and ABI have no libXray asset.
  final String? Function() assetName;
  final CoreCatalogRequest _request;
  final DateTime Function() _now;

  CoreCatalog({
    required this.storage,
    String? Function()? assetName,
    CoreCatalogRequest? request,
    DateTime Function()? now,
  }) : assetName = assetName ?? _currentAssetName,
       _request = request ?? _githubRequest,
       _now = now ?? DateTime.now;

  /// Fetches releases for the selected asset. A fresh cache answers without
  /// network; an expired cache revalidates with If-None-Match and keeps
  /// serving its releases on 304. Transport failures fall back to the cache
  /// and report [CoreCatalogResult.stale].
  Future<CoreCatalogResult> fetch({bool forceRefresh = false}) async {
    final selectedAsset = assetName();
    if (selectedAsset == null) {
      throw const AppFailure(
        FailureCategory.configuration,
        'corePlatformUnsupported',
        cause: 'No libXray release asset exists for this platform and ABI',
      );
    }
    final cached = await _readCache();
    final now = _now();
    if (!forceRefresh &&
        cached != null &&
        now.difference(cached.fetchedAt) < cacheTtl) {
      return _result(cached, fromCache: true, stale: false);
    }
    final requestHeaders = <String, String>{
      'accept': 'application/vnd.github+json',
      if (cached?.etag != null) 'if-none-match': cached!.etag!,
    };
    CoreCatalogResponse response;
    try {
      response = await _request(releasesUri, requestHeaders);
    } on AppFailure {
      rethrow;
    } catch (error) {
      if (cached != null) {
        return _result(cached, fromCache: true, stale: true);
      }
      throw AppFailure(
        FailureCategory.network,
        'catalogUnavailable',
        cause: error,
      );
    }
    if (response.statusCode == HttpStatus.notModified) {
      if (cached == null) {
        throw const AppFailure(
          FailureCategory.network,
          'catalogUnavailable',
          cause: 'GitHub reported 304 without a cached catalog',
        );
      }
      final refreshed = _CatalogCache(
        etag: cached.etag,
        fetchedAt: now,
        releases: cached.releases,
      );
      await _writeCache(refreshed);
      return _result(refreshed, fromCache: true, stale: false);
    }
    if (_rateLimitStatuses.contains(response.statusCode)) {
      throw AppFailure(
        FailureCategory.network,
        'catalogRateLimited',
        cause: response.body,
      );
    }
    if (response.statusCode != HttpStatus.ok) {
      throw AppFailure(
        FailureCategory.network,
        'catalogHttp',
        cause: 'HTTP ${response.statusCode}',
      );
    }
    final releases = _parseReleases(response.body, selectedAsset);
    final fresh = _CatalogCache(
      etag: response.etag,
      fetchedAt: now,
      releases: releases,
    );
    await _writeCache(fresh);
    return _result(fresh, fromCache: false, stale: false);
  }

  static String? _currentAssetName() {
    final platform = currentCorePlatform();
    return platform == null
        ? null
        : coreAssetNameFor(platform, currentCoreAbi());
  }

  CoreCatalogResult _result(
    _CatalogCache cache, {
    required bool fromCache,
    required bool stale,
  }) => CoreCatalogResult(
    releases: cache.releases,
    fetchedAt: cache.fetchedAt,
    fromCache: fromCache,
    stale: stale,
  );

  Future<_CatalogCache?> _readCache() async {
    final json = await storage.readJsonObject(storage.catalogFile);
    if (json == null) {
      return null;
    }
    final etag = json['etag'];
    final fetchedAt = json['fetchedAt'];
    final rawReleases = json['releases'];
    if (fetchedAt is! String || rawReleases is! List) {
      return null;
    }
    final fetched = DateTime.tryParse(fetchedAt);
    if (fetched == null) {
      return null;
    }
    try {
      final releases = [
        for (final entry in rawReleases)
          if (entry is Map)
            CoreRelease.fromJson(entry.cast<String, dynamic>())
          else
            throw const AppFailure(
              FailureCategory.input,
              'coreCatalogCache',
              cause: 'Cached release entry is not an object',
            ),
      ];
      return _CatalogCache(
        etag: etag is String ? etag : null,
        fetchedAt: fetched,
        releases: releases,
      );
    } on AppFailure {
      return null;
    }
  }

  Future<void> _writeCache(_CatalogCache cache) =>
      storage.writeJsonAtomically(storage.catalogFile, {
        if (cache.etag != null) 'etag': cache.etag,
        'fetchedAt': cache.fetchedAt.toIso8601String(),
        'releases': [for (final release in cache.releases) release.toJson()],
      });

  /// Keeps CalVer tags with an asset for the selected platform and ABI,
  /// newest publication first. Prerelease entries are preserved.
  static List<CoreRelease> filterReleases(
    Iterable<CoreRelease> releases,
    String asset,
  ) {
    final filtered = releases
        .where((release) => CoreRelease.isCatalogTag(release.tag))
        .where((release) => release.assetNamed(asset) != null)
        .toList();
    filtered.sort(
      (left, right) => right.publishedAt.compareTo(left.publishedAt),
    );
    return filtered;
  }

  static List<CoreRelease> _parseReleases(String body, String selectedAsset) {
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException catch (error) {
      throw AppFailure(
        FailureCategory.input,
        'coreCatalogResponse',
        cause: error,
      );
    }
    if (decoded is! List) {
      throw const AppFailure(
        FailureCategory.input,
        'coreCatalogResponse',
        cause: 'GitHub releases response is not a list',
      );
    }
    final releases = <CoreRelease>[];
    for (final entry in decoded) {
      if (entry is! Map) {
        throw const AppFailure(
          FailureCategory.input,
          'coreCatalogResponse',
          cause: 'GitHub release entry is not an object',
        );
      }
      releases.add(CoreRelease.fromJson(entry.cast<String, dynamic>()));
    }
    return filterReleases(releases, selectedAsset);
  }

  /// The dart:io transport used in production: HTTPS only, bounded
  /// redirects, and the shared download User-Agent.
  static Future<CoreCatalogResponse> _githubRequest(
    Uri uri,
    Map<String, String> headers,
  ) async {
    await NetClient().asyncInit();
    var current = uri;
    for (var redirects = 0; redirects <= _maxRedirects; redirects++) {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10);
      try {
        final request = await client.getUrl(current);
        request.followRedirects = false;
        headers.forEach((name, value) => request.headers.set(name, value));
        request.headers.set(
          HttpHeaders.userAgentHeader,
          NetClient().downloadUserAgent,
        );
        final response = await request.close().timeout(
          const Duration(seconds: 60),
        );
        if ({301, 302, 303, 307, 308}.contains(response.statusCode)) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          if (location == null) {
            throw const AppFailure(
              FailureCategory.network,
              'catalogRedirect',
              cause: 'Catalog redirect has no location',
            );
          }
          current = current.resolve(location);
          if (current.scheme != 'https' || current.host.isEmpty) {
            throw const AppFailure(
              FailureCategory.network,
              'catalogRedirect',
              cause: 'Catalog left the HTTPS origin',
            );
          }
          continue;
        }
        return (
          statusCode: response.statusCode,
          etag: response.headers.value('etag'),
          body: await _readBody(response),
        );
      } finally {
        client.close(force: true);
      }
    }
    throw const AppFailure(
      FailureCategory.network,
      'catalogRedirect',
      cause: 'Too many catalog redirects',
    );
  }

  static Future<String> _readBody(HttpClientResponse response) async {
    final chunks = <int>[];
    await for (final chunk in response) {
      chunks.addAll(chunk);
      if (chunks.length > _maxBodyBytes) {
        throw const AppFailure(
          FailureCategory.network,
          'catalogResponse',
          cause: 'Catalog response exceeds the 8 MiB limit',
        );
      }
    }
    return utf8.decode(chunks, allowMalformed: true);
  }
}
