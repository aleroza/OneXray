import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:onexray/core/errors/failure.dart';
import 'package:onexray/service/advanced/xray/core_version/catalog.dart';
import 'package:onexray/service/advanced/xray/core_version/storage.dart';

import '../../../../support/test_directory.dart';

const _asset = 'libxray-linux-x64.zip';
const _digest =
    'sha256:'
    '0123456789abcdef'
    '0123456789abcdef'
    '0123456789abcdef'
    '0123456789abcdef';

Map<String, dynamic> githubRelease(
  String tag,
  String publishedAt, {
  bool prerelease = false,
  bool withAsset = true,
}) => {
  'tag_name': tag,
  'published_at': publishedAt,
  'prerelease': prerelease,
  'assets': [
    if (withAsset)
      {
        'id': tag.hashCode.abs() % 1000,
        'name': _asset,
        'size': 4096,
        'digest': _digest,
        'browser_download_url': 'https://example.invalid/$_asset',
      },
  ],
};

void main() {
  late Directory root;
  late CoreVersionStorage storage;
  final now = DateTime.utc(2026, 11, 16, 12);

  CoreCatalog catalogWith(
    CoreCatalogRequest request, {
    String? Function()? assetName,
  }) => CoreCatalog(
    storage: storage,
    assetName: assetName ?? () => _asset,
    request: request,
    now: () => now,
  );

  setUp(() async {
    root = await createTestDirectory('core-catalog');
    storage = CoreVersionStorage(root);
  });

  test('keeps CalVer releases with the platform asset, newest first', () async {
    final body = jsonEncode([
      githubRelease('v26.11.9', '2026-11-09T10:00:00Z'),
      githubRelease('v1.261109.0', '2026-11-09T09:00:00Z'),
      githubRelease('v23.12.31', '2026-11-08T09:00:00Z'),
      githubRelease('v26.1.99', '2026-11-08T10:00:00Z'),
      githubRelease('v26.1.2', '2026-10-02T10:00:00Z', prerelease: true),
      githubRelease('v26.3.3', '2026-03-03T10:00:00Z', withAsset: false),
    ]);
    String? seenAccept;
    final catalog = catalogWith((uri, headers) async {
      expect(
        uri.toString(),
        'https://api.github.com/repos/XTLS/libXray/releases?per_page=100',
      );
      seenAccept = headers['accept'];
      return (statusCode: 200, etag: 'E1', body: body);
    });

    final result = await catalog.fetch();
    expect(seenAccept, 'application/vnd.github+json');
    expect(result.releases.map((release) => release.tag), [
      'v26.11.9',
      'v26.1.2',
    ]);
    expect(result.releases[1].prerelease, isTrue, reason: 'prerelease kept');
    expect(result.fromCache, isFalse);
    expect(result.stale, isFalse);
    expect(result.fetchedAt, now);

    final cache = await storage.readJsonObject(storage.catalogFile);
    expect(cache!['etag'], 'E1');
    expect(cache['fetchedAt'], now.toIso8601String());
  });

  test('an unsupported platform never reaches the network', () async {
    final catalog = catalogWith(
      (uri, headers) async => fail('no request expected'),
      assetName: () => null,
    );
    await expectLater(
      catalog.fetch(),
      throwsA(
        isA<AppFailure>()
            .having(
              (failure) => failure.category,
              'category',
              FailureCategory.configuration,
            )
            .having(
              (failure) => failure.code,
              'code',
              'corePlatformUnsupported',
            ),
      ),
    );
  });

  test('a cache within the TTL answers without a request', () async {
    final body = jsonEncode([
      githubRelease('v26.11.9', '2026-11-09T10:00:00Z'),
    ]);
    final fetches = <String, String>{};
    final catalog = catalogWith((uri, headers) async {
      fetches.addAll(headers);
      return (statusCode: 200, etag: 'E1', body: body);
    });
    await catalog.fetch();
    final second = await catalog.fetch();
    expect(second.fromCache, isTrue);
    expect(second.stale, isFalse);
    expect(second.releases.single.tag, 'v26.11.9');
    expect(fetches.containsKey('if-none-match'), isFalse);
  });

  test('a revalidated cache serves 304 answers and keeps its ETag', () async {
    await seedCache(
      storage,
      etag: 'E1',
      fetchedAt: now.subtract(const Duration(days: 2)),
    );
    Map<String, String>? sentHeaders;
    final catalog = catalogWith((uri, headers) async {
      sentHeaders = headers;
      return (statusCode: 304, etag: null, body: '');
    });

    final result = await catalog.fetch();
    expect(sentHeaders!['if-none-match'], 'E1');
    expect(result.fromCache, isTrue);
    expect(result.stale, isFalse);
    expect(result.releases.single.tag, 'v26.11.9');
    expect(result.fetchedAt, now);
    final cache = await storage.readJsonObject(storage.catalogFile);
    expect(cache!['etag'], 'E1');
  });

  test('transport failures fall back to the cache as stale', () async {
    await seedCache(
      storage,
      etag: 'E1',
      fetchedAt: now.subtract(const Duration(days: 2)),
    );
    final catalog = catalogWith(
      (uri, headers) async => throw const SocketException('no route'),
    );
    final result = await catalog.fetch();
    expect(result.fromCache, isTrue);
    expect(result.stale, isTrue);
    expect(result.releases.single.tag, 'v26.11.9');
  });

  test('offline without a cache fails as catalogUnavailable', () async {
    final catalog = catalogWith(
      (uri, headers) async =>
          throw TimeoutException('catalog request timed out'),
    );
    await expectLater(
      catalog.fetch(),
      throwsA(
        isA<AppFailure>()
            .having(
              (failure) => failure.category,
              'category',
              FailureCategory.network,
            )
            .having((failure) => failure.code, 'code', 'catalogUnavailable'),
      ),
    );
  });

  test('403 and 429 report the GitHub body', () async {
    for (final status in [403, 429]) {
      final catalog = catalogWith(
        (uri, headers) async => (
          statusCode: status,
          etag: null,
          body: '{"message":"API rate limit exceeded"}',
        ),
      );
      await expectLater(
        catalog.fetch(),
        throwsA(
          isA<AppFailure>()
              .having(
                (failure) => failure.category,
                'category',
                FailureCategory.network,
              )
              .having((failure) => failure.code, 'code', 'catalogRateLimited')
              .having(
                (failure) => failure.cause.toString(),
                'cause',
                contains('rate limit'),
              ),
        ),
        reason: 'HTTP $status',
      );
    }
  });

  test('a garbage catalog body fails as input', () async {
    final catalog = catalogWith(
      (uri, headers) async => (statusCode: 200, etag: null, body: 'not json'),
    );
    await expectLater(
      catalog.fetch(),
      throwsA(isInputFailure('coreCatalogResponse')),
    );
    final list = catalogWith(
      (uri, headers) async => (statusCode: 200, etag: null, body: '{"a":1}'),
    );
    await expectLater(
      list.fetch(),
      throwsA(isInputFailure('coreCatalogResponse')),
    );
  });
}

Future<void> seedCache(
  CoreVersionStorage storage, {
  required String etag,
  required DateTime fetchedAt,
}) => storage.writeJsonAtomically(storage.catalogFile, {
  'etag': etag,
  'fetchedAt': fetchedAt.toIso8601String(),
  'releases': [githubRelease('v26.11.9', '2026-11-09T10:00:00Z')],
});

Matcher isInputFailure(String code) => isA<AppFailure>()
    .having((failure) => failure.category, 'category', FailureCategory.input)
    .having((failure) => failure.code, 'code', code);
