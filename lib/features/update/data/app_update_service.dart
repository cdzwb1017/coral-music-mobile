import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

final class AppRelease {
  const AppRelease({
    required this.version,
    required this.title,
    required this.notes,
    required this.releaseUrl,
    this.assetName,
    this.downloadUrl,
  });

  final String version;
  final String title;
  final String notes;
  final Uri releaseUrl;
  final String? assetName;
  final Uri? downloadUrl;
}

final class AppUpdateService {
  AppUpdateService(this._dio,
      [FlutterSecureStorage storage = const FlutterSecureStorage()])
      : _storage = storage;

  final Dio _dio;
  final FlutterSecureStorage _storage;
  static const _channel = MethodChannel('coral_music/app_update');
  static const _latestRelease =
      'https://api.github.com/repos/vien-meng/coral-music-mobile/releases/latest';
  static const _ignoredVersionKey = 'updates:ignored-version';

  Future<AppRelease?> checkForUpdate() async {
    if (!Platform.isAndroid && !Platform.isIOS) return null;
    try {
      final platform = await _channel.invokeMapMethod<String, String>('info');
      final currentVersion = platform?['version'];
      if (currentVersion == null) return null;
      final response = await _dio.get<Map<String, dynamic>>(
        _latestRelease,
        options: Options(headers: const {
          'Accept': 'application/vnd.github+json',
          'X-GitHub-Api-Version': '2022-11-28',
        }),
      );
      final abi =
          Platform.isAndroid && platform != null ? platform['abi'] : null;
      final release = parseGitHubRelease(response.data, abi: abi);
      if (release == null ||
          !isNewerVersion(release.version, currentVersion) ||
          await _storage.read(key: _ignoredVersionKey) == release.version) {
        return null;
      }
      return release;
    } on Object {
      // Automatic checks must never block startup.
      return null;
    }
  }

  Future<void> ignore(AppRelease release) =>
      _storage.write(key: _ignoredVersionKey, value: release.version);

  Future<bool> downloadAndInstall(AppRelease release) async {
    final url = release.downloadUrl;
    final name = release.assetName;
    if (!Platform.isAndroid || url == null || name == null) return false;
    try {
      return await _channel.invokeMethod<bool>('downloadAndInstall', {
            'url': url.toString(),
            'name': name,
          }) ??
          false;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> openRelease(AppRelease release) async {
    try {
      return await _channel.invokeMethod<bool>('openRelease', {
            'url': release.releaseUrl.toString(),
          }) ??
          false;
    } on PlatformException {
      return false;
    }
  }
}

AppRelease? parseGitHubRelease(Map<String, dynamic>? json, {String? abi}) {
  if (json == null) return null;
  final version = json['tag_name'];
  final releaseUrl = Uri.tryParse(json['html_url']?.toString() ?? '');
  if (version is! String ||
      releaseUrl == null ||
      !releaseUrl.isScheme('https') ||
      releaseUrl.host != 'github.com' ||
      !releaseUrl.path
          .startsWith('/vien-meng/coral-music-mobile/releases/tag/')) {
    return null;
  }
  if (abi == null) {
    return AppRelease(
      version: version,
      title: json['name']?.toString() ?? version,
      notes: json['body']?.toString() ?? '',
      releaseUrl: releaseUrl,
    );
  }
  final rawAssets = json['assets'];
  if (rawAssets is! List) return null;
  final assets = rawAssets.whereType<Map>().where((asset) {
    final name = asset['name']?.toString().toLowerCase() ?? '';
    return name.endsWith('.apk');
  }).toList(growable: false);
  final lowerAbi = abi.toLowerCase();
  final architectureNames = ['arm64-v8a', 'armeabi-v7a', 'x86_64', 'x86'];
  final asset = assets.where((item) {
        return item['name'].toString().toLowerCase().contains(lowerAbi);
      }).firstOrNull ??
      assets.where((item) {
        final name = item['name'].toString().toLowerCase();
        return name.contains('universal') ||
            !architectureNames.any(name.contains);
      }).firstOrNull;
  final name = asset?['name'];
  final url = Uri.tryParse(asset?['browser_download_url']?.toString() ?? '');
  if (name is! String || url == null || !url.isScheme('https')) return null;
  return AppRelease(
    version: version,
    title: json['name']?.toString() ?? version,
    notes: json['body']?.toString() ?? '',
    releaseUrl: releaseUrl,
    assetName: name,
    downloadUrl: url,
  );
}

bool isNewerVersion(String candidate, String current) {
  final candidateParts = _versionParts(candidate);
  final currentParts = _versionParts(current);
  for (var index = 0;
      index < candidateParts.length || index < currentParts.length;
      index++) {
    final next = index < candidateParts.length ? candidateParts[index] : 0;
    final installed = index < currentParts.length ? currentParts[index] : 0;
    if (next != installed) return next > installed;
  }
  return false;
}

List<int> _versionParts(String version) => RegExp(r'\d+')
    .allMatches(version)
    .map((match) => int.parse(match.group(0)!))
    .toList(growable: false);
