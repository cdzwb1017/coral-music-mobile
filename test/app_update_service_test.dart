import 'package:coral_music_mobile/features/update/data/app_update_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('selects the device APK and compares release versions', () {
    final release = parseGitHubRelease({
      'tag_name': 'v1.1.0',
      'name': '1.1.0',
      'body': '更新说明',
      'assets': [
        {
          'name': 'coral-1.1.0-armeabi-v7a-release.apk',
          'browser_download_url': 'https://github.com/a/armeabi.apk',
        },
        {
          'name': 'coral-1.1.0-arm64-v8a-release.apk',
          'browser_download_url': 'https://github.com/a/arm64.apk',
        },
      ],
      'html_url':
          'https://github.com/vien-meng/coral-music-mobile/releases/tag/v1.1.0',
    }, abi: 'arm64-v8a');

    expect(release?.assetName, contains('arm64-v8a'));
    expect(
      parseGitHubRelease({
        'tag_name': 'v1.1.0',
        'html_url':
            'https://github.com/vien-meng/coral-music-mobile/releases/tag/v1.1.0',
      })?.releaseUrl.path,
      '/vien-meng/coral-music-mobile/releases/tag/v1.1.0',
    );
    expect(isNewerVersion('v1.1.0', '1.0.9'), isTrue);
    expect(isNewerVersion('v1.0.4', '1.0.4'), isFalse);
    expect(isNewerVersion('v1.0.3', '1.0.4'), isFalse);
  });
}
