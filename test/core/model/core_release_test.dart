import 'package:flutter_test/flutter_test.dart';
import 'package:onexray/core/errors/failure.dart';
import 'package:onexray/core/model/core_release.dart';

const _validHex =
    '0123456789abcdef'
    '0123456789abcdef'
    '0123456789abcdef'
    '0123456789abcdef';
const _upperHex =
    '0123456789ABCDEF'
    '0123456789ABCDEF'
    '0123456789ABCDEF'
    '0123456789ABCDEF';
const _validDigest = 'sha256:$_validHex';

Map<String, dynamic> githubAsset({
  int id = 7,
  String name = 'libxray-linux-x64.zip',
  int size = 100,
  Object? digest = _validDigest,
}) => {
  'id': id,
  'name': name,
  'size': size,
  'digest': ?digest,
  'browser_download_url': 'https://example.invalid/$name',
};

Map<String, dynamic> githubRelease({
  Object? tag = 'v26.11.9',
  Object? publishedAt = '2026-11-09T10:00:00Z',
  Object? prerelease = false,
  Object? assets = const [],
}) => {
  'tag_name': ?tag,
  'published_at': ?publishedAt,
  'prerelease': ?prerelease,
  'assets': ?assets,
};

Matcher isInputFailure(String code) => isA<AppFailure>()
    .having((failure) => failure.category, 'category', FailureCategory.input)
    .having((failure) => failure.code, 'code', code);

void main() {
  group('parsing', () {
    test('parses a GitHub release with its verified asset', () {
      final release = CoreRelease.fromJson(
        githubRelease(
          prerelease: true,
          assets: [githubAsset(id: 42, size: 2048)],
        ),
      );
      expect(release.tag, 'v26.11.9');
      expect(release.publishedAt, DateTime.utc(2026, 11, 9, 10));
      expect(release.prerelease, isTrue);
      final asset = release.assetNamed('libxray-linux-x64.zip');
      expect(asset, isNotNull);
      expect(asset!.id, 42);
      expect(asset.size, 2048);
      expect(asset.digest, _validDigest);
      expect(
        asset.downloadUrl,
        'https://example.invalid/libxray-linux-x64.zip',
      );
      expect(release.assetNamed('libxray-windows-x64.zip'), isNull);
    });

    test('assets without a sha256 digest are dropped', () {
      final release = CoreRelease.fromJson(
        githubRelease(
          assets: [
            githubAsset(id: 1, digest: null),
            githubAsset(id: 2, digest: 'md5:${'ab' * 16}'),
            githubAsset(id: 3, digest: 'sha256:oops'),
            githubAsset(id: 4, digest: 17),
            githubAsset(id: 5, name: 'libxray-linux-arm64.zip'),
          ],
        ),
      );
      expect(release.assets.map((asset) => asset.id), [5]);
      expect(CoreAsset.tryParse(githubAsset(digest: null)), isNull);
    });

    test('digest hex is extracted and lowercased', () {
      const asset = CoreAsset(
        id: 1,
        name: 'libxray-linux-x64.zip',
        size: 1,
        digest: 'sha256:$_upperHex',
        downloadUrl: 'https://example.invalid/a.zip',
      );
      expect(asset.sha256Hex, _validHex);
      expect(
        const CoreAsset(
          id: 1,
          name: 'a.zip',
          size: 1,
          downloadUrl: 'https://example.invalid/a.zip',
        ).sha256Hex,
        isNull,
      );
      expect(
        const CoreAsset(
          id: 1,
          name: 'a.zip',
          size: 1,
          digest: 'sha512:$_validHex$_validHex',
          downloadUrl: 'https://example.invalid/a.zip',
        ).sha256Hex,
        isNull,
      );
    });

    test('the published JSON shape round-trips through the cache', () {
      final release = CoreRelease.fromJson(
        githubRelease(assets: [githubAsset(id: 9)]),
      );
      expect(CoreRelease.fromJson(release.toJson()).tag, release.tag);
      expect(
        CoreRelease.fromJson(release.toJson())
            .assetNamed('libxray-linux-x64.zip')
            ?.digest,
        _validDigest,
      );
    });

    test('garbage responses fail as input errors', () {
      expect(
        () => CoreRelease.fromJson(githubRelease(tag: 123)),
        throwsA(isInputFailure('coreRelease')),
      );
      expect(
        () => CoreRelease.fromJson(githubRelease(tag: null)),
        throwsA(isInputFailure('coreRelease')),
      );
      expect(
        () => CoreRelease.fromJson(githubRelease(publishedAt: 'soon')),
        throwsA(isInputFailure('coreRelease')),
      );
      expect(
        () => CoreRelease.fromJson(githubRelease(publishedAt: null)),
        throwsA(isInputFailure('coreRelease')),
      );
      expect(
        () => CoreRelease.fromJson(githubRelease(prerelease: 'no')),
        throwsA(isInputFailure('coreRelease')),
      );
      expect(
        () => CoreRelease.fromJson(githubRelease(assets: {})),
        throwsA(isInputFailure('coreRelease')),
      );
      expect(
        () => CoreRelease.fromJson(githubRelease(assets: ['not-an-asset'])),
        throwsA(isInputFailure('coreReleaseAsset')),
      );
      expect(
        () => CoreRelease.fromJson(
          githubRelease(
            assets: [
              {'id': 1, 'name': 'a.zip', 'size': 1},
            ],
          ),
        ),
        throwsA(isInputFailure('coreReleaseAsset')),
      );
    });
  });

  group('isCatalogTag', () {
    test('accepts plausible CalVer tags', () {
      for (final tag in ['v24.1.1', 'v26.11.9', 'v26.01.09', 'v99.12.31']) {
        expect(CoreRelease.isCatalogTag(tag), isTrue, reason: tag);
      }
    });

    test('rejects Go mirrors, old majors and impossible dates', () {
      for (final tag in [
        'v1.261109.0',
        'v1.0.0',
        'v23.12.31',
        'v26.13.1',
        'v26.0.1',
        'v26.1.32',
        'v26.1.0',
        'v26.11',
        'v26.11.9.1',
        'v260.1.1',
        'V26.11.9',
        'v26.11.9-rc1',
        'release-v26.11.9',
        'latest',
      ]) {
        expect(CoreRelease.isCatalogTag(tag), isFalse, reason: tag);
      }
    });
  });
}
