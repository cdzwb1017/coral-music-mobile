import 'package:flutter/foundation.dart';

import '../../../core/app_failure.dart';
import '../../../domain/music.dart';
import '../../webdav/data/webdav_credentials.dart';
import 'user_api_runner.dart';

final class PlaybackResolver {
  PlaybackResolver(this._userApiRunner, [WebDavCredentials? webDavCredentials])
      : _webDavCredentials = webDavCredentials ?? WebDavCredentials();

  final UserApiRunner _userApiRunner;
  final WebDavCredentials _webDavCredentials;
  final _cachedUrls = <String, _CachedPlaybackUrl>{};
  // 同一 key 的 resolve 请求去重，避免 _prepareNextTrack 与 playTrack 并发
  // resolve 同一首歌导致两次 native 调用（resolveCount 虚高、后台 JSContext 压力倍增）。
  final _inFlight = <String, Future<ResolvedPlaybackUrl>>{};
  Future<void>? _userApiInitialization;

  // 后台/锁屏时 JSContext 可能失效，无法 resolve 新 URL。
  // 延长缓存 TTL 确保预 resolve 的 URL 在整个播放列表播放期间不过期。
  static const _urlCacheLifetime = Duration(hours: 2);

  /// The persisted User API script loads asynchronously at launch. Online
  /// requests must not race the WebView reset performed by that load.
  void setUserApiInitialization(Future<void> initialization) {
    _userApiInitialization = initialization;
  }

  Future<ResolvedPlaybackUrl> resolve(
    Track track, {
    AudioQuality? quality,
    bool forceRefresh = false,
  }) async {
    if (track.sourceKind == TrackSourceKind.webdav) {
      final uri = track.localUri;
      final authorization = await _webDavCredentials.read(track.sourceId);
      if (uri != null && authorization != null && authorization.isNotEmpty) {
        return ResolvedPlaybackUrl(uri,
            headers: {'Authorization': authorization});
      }
      throw const AppFailure(
        code: AppFailureCode.invalidData,
        message: 'WebDAV 凭据已失效，请重新连接',
      );
    }
    if (track.sourceKind != TrackSourceKind.online) {
      final uri = track.localUri;
      if (uri != null) return ResolvedPlaybackUrl(uri);
      throw const AppFailure(
        code: AppFailureCode.invalidData,
        message: '该来源缺少播放地址',
      );
    }
    await _userApiInitialization;
    final resolvedQuality =
        quality ?? defaultPlaybackQuality(track.availableQualities);
    final key = _cacheKey(track, resolvedQuality);
    final cached = _cachedUrls[key];
    if (!forceRefresh &&
        cached != null &&
        cached.expiresAt.isAfter(DateTime.now())) {
      debugPrint('[BG] resolver CACHE HIT: id=${track.id} key=$key url=${cached.playbackUrl.uri}');
      return cached.playbackUrl;
    }
    debugPrint('[BG] resolver CACHE MISS: id=${track.id} key=$key forceRefresh=$forceRefresh '
        'hasCached=${cached != null} expired=${cached != null && !cached.expiresAt.isAfter(DateTime.now())}');
    // 同一 key 的并发 resolve 去重：若已有 in-flight 请求，复用其 Future。
    // forceRefresh=true 的请求不参与去重（需要强制刷新拿新 URL）。
    final inflightKey = '$key:$forceRefresh';
    final existing = _inFlight[inflightKey];
    if (existing != null) {
      debugPrint('[BG] resolver DEDUP: id=${track.id} key=$key 复用 in-flight 请求');
      return existing;
    }
    final future = _userApiRunner.resolveMusicUrl(track, resolvedQuality);
    _inFlight[inflightKey] = future;
    try {
      final playbackUrl = await future;
      _cachedUrls[key] = _CachedPlaybackUrl(
        playbackUrl: playbackUrl,
        expiresAt: DateTime.now().add(_urlCacheLifetime),
      );
      debugPrint('[BG] resolver RESOLVED: id=${track.id} url=${playbackUrl.uri}');
      return playbackUrl;
    } finally {
      _inFlight.remove(inflightKey);
    }
  }

  /// 只读缓存中的 URL，不触发 JSContext/网络请求。
  /// 用于后台预加载时检查 URL 是否已缓存，
  /// 避免在后台触发 JSContext HTTP 请求导致 iOS 挂起 app。
  ResolvedPlaybackUrl? getCachedUrl(Track track, {AudioQuality? quality}) {
    if (track.sourceKind != TrackSourceKind.online) return null;
    final resolvedQuality =
        quality ?? defaultPlaybackQuality(track.availableQualities);
    final key = _cacheKey(track, resolvedQuality);
    final cached = _cachedUrls[key];
    if (cached != null && cached.expiresAt.isAfter(DateTime.now())) {
      return cached.playbackUrl;
    }
    return null;
  }

  void invalidate(Track track, {AudioQuality? quality}) {
    final resolvedQuality =
        quality ?? defaultPlaybackQuality(track.availableQualities);
    _cachedUrls.remove(_cacheKey(track, resolvedQuality));
    _cachedUrls.removeWhere(
      (key, cached) =>
          key.startsWith('${track.id}:') &&
          cached.playbackUrl.quality == resolvedQuality,
    );
  }

  void clear() => _cachedUrls.clear();

  String _cacheKey(Track track, AudioQuality quality) =>
      '${track.id}:${quality.name}';
}

final class _CachedPlaybackUrl {
  const _CachedPlaybackUrl({
    required this.playbackUrl,
    required this.expiresAt,
  });

  final ResolvedPlaybackUrl playbackUrl;
  final DateTime expiresAt;
}
