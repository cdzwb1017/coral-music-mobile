import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_failure.dart';
import '../../../domain/music.dart';
import '../../library/data/library_store.dart';
import '../data/audio_engine.dart';
import '../data/audio_file_probe.dart';
import '../data/native_playback_bridge.dart';
import '../data/playback_resolver.dart';
import '../data/track_artwork_resolver.dart';
import '../data/user_api_runner.dart';
import '../../leaderboard/state/leaderboard_controller.dart';
import 'playback_queue_controller.dart';

final userApiRunnerProvider =
    Provider<UserApiRunner>((ref) => MethodChannelUserApiRunner());

final playbackResolverProvider = Provider<PlaybackResolver>(
  (ref) => PlaybackResolver(ref.watch(userApiRunnerProvider)),
);

final audioEngineProvider = Provider<AudioEngine>((ref) {
  final engine = JustAudioEngine();
  ref.onDispose(engine.dispose);
  return engine;
});

final nativePlaybackBridgeProvider = Provider<NativePlaybackBridge>((ref) {
  final bridge = NativePlaybackBridge();
  ref.onDispose(bridge.dispose);
  return bridge;
});

final audioFileProbeProvider =
    Provider<AudioFileProbe>((_) => HttpAudioFileProbe());

final trackArtworkResolverProvider = Provider<TrackArtworkResolver>(
  (ref) => TrackArtworkResolver(ref.watch(onlineCatalogServicesProvider)),
);

final playerProvider = StateNotifierProvider<PlayerController, PlayerState>(
  (ref) => PlayerController(
    ref.watch(audioEngineProvider),
    ref.watch(playbackResolverProvider),
    ref.watch(playbackQueueProvider.notifier),
    ref.watch(libraryStoreProvider),
    ref.watch(audioFileProbeProvider),
    ref.watch(trackArtworkResolverProvider),
    null,
    ref.watch(nativePlaybackBridgeProvider),
  ),
);

final class PlayerState {
  const PlayerState({
    this.track,
    this.position = Duration.zero,
    this.duration,
    this.status = AudioEngineStatus.idle,
    this.speed = 1,
    this.volume = 1,
    this.quality = AudioQuality.flac,
    this.sleepTimerEndsAt,
    this.stopAfterCurrent = false,
    this.fileInfo,
    this.error,
  });

  final Track? track;
  final Duration position;
  final Duration? duration;
  final AudioEngineStatus status;
  final double speed;
  final double volume;
  final AudioQuality quality;
  final DateTime? sleepTimerEndsAt;
  final bool stopAfterCurrent;
  final AudioFileInfo? fileInfo;
  final AppFailure? error;

  bool get isPlaying => status == AudioEngineStatus.playing;

  PlayerState copyWith({
    Track? track,
    Duration? position,
    Duration? duration,
    AudioEngineStatus? status,
    double? speed,
    double? volume,
    AudioQuality? quality,
    DateTime? sleepTimerEndsAt,
    bool? stopAfterCurrent,
    AudioFileInfo? fileInfo,
    AppFailure? error,
    bool clearError = false,
    bool clearFileInfo = false,
    bool clearSleepTimer = false,
  }) =>
      PlayerState(
        track: track ?? this.track,
        position: position ?? this.position,
        duration: duration ?? this.duration,
        status: status ?? this.status,
        speed: speed ?? this.speed,
        volume: volume ?? this.volume,
        quality: quality ?? this.quality,
        sleepTimerEndsAt:
            clearSleepTimer ? null : sleepTimerEndsAt ?? this.sleepTimerEndsAt,
        stopAfterCurrent: stopAfterCurrent ?? this.stopAfterCurrent,
        fileInfo: clearFileInfo ? null : fileInfo ?? this.fileInfo,
        error: clearError ? null : error ?? this.error,
      );
}

final class PlayerController extends StateNotifier<PlayerState> {
  PlayerController(
    this._engine,
    this._resolver,
    this._queue, [
    LibraryStore? library,
    AudioFileProbe? fileProbe,
    TrackArtworkResolver? artworkResolver,
    Future<List<PlayHistoryEntry>> Function()? loadHistory,
    NativePlaybackBridge? nativePlayback,
  ])  : _library = library ?? LibraryStore(),
        _fileProbe = fileProbe ?? const NoopAudioFileProbe(),
        _artworkResolver = artworkResolver,
        _nativePlayback = nativePlayback,
        super(const PlayerState()) {
    _loadHistory = loadHistory ?? _library.listHistory;
    _subscription = _engine.snapshots.listen(_onSnapshot);
    _engineCommandSubscription = _engine.commands.listen(_onEngineCommand);
    // 锁屏/控制中心拖动进度条时，SeekHandler.seek 直接调用 just_audio 的 seek，
    // 绕过 PlayerController.seek。这会导致 _seekTarget 未设置，
    // just_audio 的 positionStream 在 seek 完成前仍 emit 旧 position，
    // _onSnapshot 用旧 position 覆盖 state.position，造成 UI 进度不一致。
    // 监听 _engine.seeks 同步 _seekTarget，与 PlayerController.seek 行为一致。
    _seekSubscription = _engine.seeks.listen((position) {
      _seekTarget = position;
      _seekTargetReset?.cancel();
      _seekTargetReset = Timer(const Duration(seconds: 5), _clearSeekTarget);
      state = state.copyWith(position: position);
    });
    _nativeStateSubscription = _nativePlayback?.states.listen(_onNativeState);
  }

  final AudioEngine _engine;
  final PlaybackResolver _resolver;
  final PlaybackQueueController _queue;
  final LibraryStore _library;
  final AudioFileProbe _fileProbe;
  final TrackArtworkResolver? _artworkResolver;
  final NativePlaybackBridge? _nativePlayback;
  late final Future<List<PlayHistoryEntry>> Function() _loadHistory;
  final _failedTrackIds = <String>{};
  final _refreshedTrackQualities = <String>{};
  final _handledEngineFailures = <String>{};
  var _playRequest = 0;
  String? _recordedHistoryTrackId;
  String? _lastPersistedTrackId;
  Duration _lastPersistedPosition = Duration.zero;
  Future<void> _historyWrites = Future.value();
  AudioQuality _preferredQuality = AudioQuality.flac;
  Timer? _sleepTimer;
  late final StreamSubscription<AudioEngineSnapshot> _subscription;
  late final StreamSubscription<AudioEngineCommand> _engineCommandSubscription;
  late final StreamSubscription<Duration> _seekSubscription;
  StreamSubscription<NativePlaybackState>? _nativeStateSubscription;
  var _usingNativeOnline = false;

  // 拖动进度条后，just_audio 的 positionStream 在 seek 完成前仍会 emit 旧 position
  // （基于系统时间插值，seek 期间需要重新缓冲），这会导致 _onSnapshot 用旧 position
  // 覆盖 state.position，使 UI 显示的进度与真实播放进度不一致。
  // 解决：seek 后记录 _seekTarget，在 just_audio 报告的 position 接近 _seekTarget 前，
  // 保留 state.position 为 _seekTarget，避免被旧 position 回退。
  Duration? _seekTarget;
  Timer? _seekTargetReset;

  // 后台连续播放核心机制：在当前歌曲即将结束时（剩余 30 秒）提前预解析接下来的歌曲。
  // iOS 后台会回收 JSContext 状态，但仅在切歌间隙（completed → loading）发生。
  // 歌曲正在播放时 audio session 活跃，JSContext 保持有效。
  // 因此在歌曲结束前触发 _prepareNextTrack，确保切歌时 URL 已缓存，
  // 不需要在 gap 中调用 JSContext，实现后台无限连续播放。
  String? _preloadedForCompletionTrackId;

  static const _positionCheckpoint = Duration(seconds: 15);
  // 歌曲剩余多少秒时触发"即将结束"预解析。
  // 30 秒足够预解析 10 首歌（每首约 2 秒），覆盖长播放列表的后台连续播放。
  static const _preloadBeforeEndThreshold = Duration(seconds: 30);
  // iOS 后台挂起应用时，native 侧的超时回调（DispatchQueue.main.asyncAfter）
  // 和 URLSession delegate 都不会执行，导致 MethodChannel 调用永不返回。
  // 这里在 Dart 侧加超时兜底，确保 state 不会永远停留在 loading。
  // resolve 给 25 秒（native 侧 20 秒超时 + 5 秒缓冲）；load 给 30 秒
  //（覆盖 just_audio setAudioSource 的网络加载）。
  static const _resolveTimeout = Duration(seconds: 25);
  static const _loadTimeout = Duration(seconds: 30);

  Future<void> toggle(Track track) async {
    if (state.track?.id == track.id && state.isPlaying) return pause();
    if (state.track?.id == track.id &&
        (state.status == AudioEngineStatus.ready ||
            state.status == AudioEngineStatus.paused)) {
      if (_usingNativeOnline) return _nativePlayback!.play();
      return _engine.play();
    }
    return playTrack(
      track,
      initialPosition: state.track?.id == track.id ? state.position : null,
    );
  }

  Future<void> retryCurrent() {
    final track = state.track;
    if (track == null) return Future.value();
    return playTrack(
      track,
      refreshUrl: true,
      initialPosition: state.position,
    );
  }

  Future<void> restoreLastPlayback() async {
    if (state.track != null) return;
    try {
      final history = await _loadHistory();
      if (state.track != null || history.isEmpty) return;
      final latest = history.first;
      state = PlayerState(
        track: latest.track,
        position: _validResumePosition(latest.track, latest.lastPosition) ??
            Duration.zero,
        speed: state.speed,
        volume: state.volume,
        quality: _defaultQuality(latest.track),
      );
    } on Object {
      // ponytail: history is optional startup context; a storage failure must not block the app shell.
    }
  }

  Future<void> playTrack(
    Track track, {
    AudioQuality? quality,
    bool retryFailed = true,
    bool refreshUrl = false,
    Duration? initialPosition,
    bool autoPlay = true,
  }) async {
    if (track.sourceKind == TrackSourceKind.online &&
        _nativePlayback?.supportsOnlineQueue == true) {
      return _playNativeOnline(track,
          quality: quality,
          autoPlay: autoPlay,
          initialPosition: initialPosition);
    }
    if (_usingNativeOnline) {
      await _nativePlayback?.stop();
      _usingNativeOnline = false;
    }
    final request = ++_playRequest;
    debugPrint('[BG] playTrack start: id=${track.id} title=${track.title} '
        'quality=${quality ?? 'default'} refreshUrl=$refreshUrl autoPlay=$autoPlay request=$request');
    // 切换曲目时清除上一首的 seek 目标，避免 _seekTarget 跨曲目残留导致新曲目
    // 的 position 被错误锁定为旧目标值。
    _clearSeekTarget();
    // 重置"即将结束"预解析标记，新曲目需要重新触发预解析。
    _preloadedForCompletionTrackId = null;
    // 仅在曲目处于 playing/paused/ready 时才需要 stop 旧音轨。
    // completed 状态下 AVPlayer 已经停止，直接 load 新音轨即可，
    // 调用 stop 会导致 AVPlayer 状态重置，在后台切换音轨时新 item 的 setRate 会失败
    // （SetRateFailed），表现为下一首卡住无声。
    if (state.track?.id != track.id &&
        (state.status == AudioEngineStatus.playing ||
            state.status == AudioEngineStatus.paused ||
            state.status == AudioEngineStatus.ready)) {
      await _engine.stop();
      if (request != _playRequest) {
        debugPrint(
            '[BG] playTrack aborted after stop (stale request): id=${track.id}');
        return;
      }
    }
    if (retryFailed) {
      _failedTrackIds.remove(track.id);
      _refreshedTrackQualities
          .removeWhere((key) => key.startsWith('${track.id}:'));
      _handledEngineFailures
          .removeWhere((key) => key.startsWith('${track.id}:'));
    }
    final resolvedQuality = quality ?? _defaultQuality(track);
    if (refreshUrl) {
      _handledEngineFailures.remove(_engineFailureKey(track, resolvedQuality));
    }
    state = PlayerState(
      track: track,
      status: AudioEngineStatus.loading,
      speed: state.speed,
      volume: state.volume,
      quality: resolvedQuality,
      fileInfo: null,
    );
    ResolvedPlaybackUrl playbackUrl;
    try {
      debugPrint(
          '[BG] playTrack resolving URL: id=${track.id} quality=$resolvedQuality');
      playbackUrl = await _resolver
          .resolve(
            track,
            quality: resolvedQuality,
            forceRefresh: refreshUrl,
          )
          .timeout(_resolveTimeout,
              onTimeout: () => throw const AppFailure(
                    code: AppFailureCode.unknown,
                    message: '播放地址解析超时',
                  ));
      debugPrint(
          '[BG] playTrack resolved URL: id=${track.id} url=${playbackUrl.uri}');
    } on AppFailure catch (error) {
      debugPrint('[BG] playTrack resolve AppFailure: id=${track.id} '
          'code=${error.code} message=${error.message} diag=${error.diagnostic}');
      if (request != _playRequest) return;
      _handleResolveFailure(
        track,
        resolvedQuality,
        error,
        initialPosition: initialPosition,
        autoPlay: autoPlay,
      );
      return;
    } on Object catch (error) {
      debugPrint('[BG] playTrack resolve unknown error: id=${track.id} '
          'type=${error.runtimeType}');
      if (request != _playRequest) return;
      _handleResolveFailure(
        track,
        resolvedQuality,
        AppFailure(
          code: AppFailureCode.unknown,
          message: '播放地址解析失败',
          diagnostic: error.runtimeType.toString(),
        ),
        initialPosition: initialPosition,
        autoPlay: autoPlay,
      );
      return;
    }
    if (request != _playRequest) {
      debugPrint(
          '[BG] playTrack aborted after resolve (stale request): id=${track.id}');
      return;
    }
    final actualQuality = playbackUrl.quality ?? resolvedQuality;
    state = state.copyWith(quality: actualQuality);
    unawaited(_probeFileInfo(request, playbackUrl.uri));
    try {
      debugPrint(
          '[BG] playTrack loading audio: id=${track.id} url=${playbackUrl.uri}');
      await _engine
          .load(track, playbackUrl.uri, headers: playbackUrl.headers)
          .timeout(_loadTimeout,
              onTimeout: () => throw const AppFailure(
                    code: AppFailureCode.unknown,
                    message: '音频加载超时',
                  ));
      debugPrint('[BG] playTrack audio loaded: id=${track.id}');
      if (request != _playRequest) return;
      final resumePosition = initialPosition == null
          ? _cueStart(track)
          : _validResumePosition(track, initialPosition);
      if (resumePosition != null) await _engine.seek(resumePosition);
      if (request != _playRequest) return;
      if (autoPlay) await _engine.play();
      debugPrint(
          '[BG] playTrack play called: id=${track.id} autoPlay=$autoPlay');
      if (request != _playRequest) return;
      unawaited(_prepareNextTrack());
      unawaited(_resolveArtwork(request, track));
    } on AppFailure catch (error) {
      debugPrint('[BG] playTrack load AppFailure: id=${track.id} '
          'code=${error.code} message=${error.message} diag=${error.diagnostic}');
      if (request != _playRequest) return;
      _handleEngineFailure(
        track,
        actualQuality,
        error,
        initialPosition: initialPosition,
        autoPlay: autoPlay,
      );
    } on Object catch (error) {
      debugPrint('[BG] playTrack load unknown error: id=${track.id} '
          'type=${error.runtimeType}');
      if (request != _playRequest) return;
      _handleEngineFailure(
        track,
        actualQuality,
        AppFailure(
          code: AppFailureCode.unknown,
          message: '播放加载失败',
          diagnostic: error.runtimeType.toString(),
        ),
        initialPosition: initialPosition,
        autoPlay: autoPlay,
      );
    }
  }

  Future<void> playDebugUrl(String rawUrl) async {
    final request = ++_playRequest;
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null || uri.scheme != 'https') {
      state = state.copyWith(
        status: AudioEngineStatus.error,
        error: const AppFailure(
          code: AppFailureCode.invalidData,
          message: '调试音频地址必须使用 HTTPS',
        ),
      );
      return;
    }
    final track = Track(
      sourceKind: TrackSourceKind.online,
      sourceId: 'debug',
      sourceTrackId: uri.toString(),
      title: '调试音频',
      artist: uri.host,
    );
    state = PlayerState(
      track: track,
      status: AudioEngineStatus.loading,
      speed: state.speed,
      volume: state.volume,
      fileInfo: null,
    );
    try {
      await _engine.load(track, uri);
      if (request != _playRequest) return;
      await _engine.play();
    } on Object catch (error, stackTrace) {
      if (request != _playRequest) return;
      assert(() {
        debugPrint('调试音频加载失败：${error.runtimeType}');
        debugPrintStack(stackTrace: stackTrace);
        return true;
      }());
      state = state.copyWith(
        status: AudioEngineStatus.error,
        error: AppFailure(
          code: AppFailureCode.unknown,
          message: '调试音频加载失败',
          diagnostic: error.runtimeType.toString(),
        ),
      );
    }
  }

  Future<void> _playNativeOnline(
    Track track, {
    AudioQuality? quality,
    Duration? initialPosition,
    required bool autoPlay,
  }) async {
    final bridge = _nativePlayback;
    if (bridge == null) return;
    var currentTrack = track;
    final artworkResolver = _artworkResolver;
    if (currentTrack.coverUri == null && artworkResolver != null) {
      try {
        final artwork = await artworkResolver.resolve(currentTrack);
        if (artwork != null) {
          currentTrack = currentTrack.copyWith(coverUri: artwork);
        }
      } on Object {
        // Artwork is optional; never block native background playback on it.
      }
    }
    final requestedQuality = quality ?? _defaultQuality(currentTrack);
    final queuedTracks = _queue.state.tracks;
    final index = queuedTracks.indexWhere((item) => item.id == currentTrack.id);
    final tracks = index < 0
        ? <Track>[currentTrack]
        : [
            for (final queuedTrack in queuedTracks)
              queuedTrack.id == currentTrack.id ? currentTrack : queuedTrack,
          ];
    final startIndex = index < 0 ? 0 : index;
    _clearSeekTarget();
    // 仅在 Flutter 引擎已初始化时才 stop，避免懒加载触发 audio_service 的
    // MediaSession 初始化。Android 端在线播放走 NativePlaybackService，
    // 若同时存在 audio_service 的 MediaSession 会导致锁屏/控制中心不显示
    // 媒体播放信息（系统优先显示空闲的 audio_service session）。
    if (_engine.isInitialized) await _engine.stop();
    _usingNativeOnline = true;
    state = PlayerState(
      track: currentTrack,
      status: AudioEngineStatus.loading,
      speed: state.speed,
      volume: state.volume,
      quality: requestedQuality,
    );
    try {
      await bridge.startQueue(
        tracks: tracks,
        index: startIndex,
        mode: _queue.state.mode,
        quality: requestedQuality,
        autoPlay: autoPlay,
      );
      if (initialPosition != null) {
        await bridge.seek(_validResumePosition(currentTrack, initialPosition) ??
            Duration.zero);
      }
    } on AppFailure catch (error) {
      _usingNativeOnline = false;
      state = state.copyWith(status: AudioEngineStatus.error, error: error);
    }
  }

  void _onNativeState(NativePlaybackState snapshot) {
    if (!_usingNativeOnline || snapshot.index < 0) return;
    final tracks = _queue.state.tracks;
    if (snapshot.index >= tracks.length) return;
    if (_queue.state.currentIndex != snapshot.index) {
      _queue.select(snapshot.index);
    }
    final track = tracks[snapshot.index];
    final quality = _qualityFromNative(snapshot.quality) ?? state.quality;
    final fileInfo = snapshot.bitrate == null && snapshot.sampleRate == null
        ? (state.track?.id == track.id ? state.fileInfo : null)
        : AudioFileInfo(
            bitrate: snapshot.bitrate,
            sampleRate: snapshot.sampleRate,
          );
    if (snapshot.status == AudioEngineStatus.playing) {
      _persistPosition(track, snapshot.position);
      if (_recordedHistoryTrackId != track.id) {
        _recordedHistoryTrackId = track.id;
        _recordHistory(track, snapshot.position);
      }
    }
    state = PlayerState(
      track: track,
      position: snapshot.position,
      duration: snapshot.duration ?? track.duration,
      status: snapshot.status,
      speed: state.speed,
      volume: state.volume,
      quality: quality,
      sleepTimerEndsAt: state.sleepTimerEndsAt,
      stopAfterCurrent: state.stopAfterCurrent,
      fileInfo: fileInfo,
      error: snapshot.error == null
          ? null
          : AppFailure(code: AppFailureCode.unknown, message: snapshot.error!),
    );
  }

  AudioQuality? _qualityFromNative(String? value) => switch (value) {
        'flac24bit' => AudioQuality.flac24bit,
        'flac' => AudioQuality.flac,
        '320k' => AudioQuality.high320k,
        '192k' => AudioQuality.high192k,
        '128k' => AudioQuality.standard128k,
        'hires' => AudioQuality.hires,
        'atmos' => AudioQuality.atmos,
        'atmos_plus' => AudioQuality.atmosPlus,
        'master' => AudioQuality.master,
        _ => null,
      };

  Future<void> _resolveArtwork(int request, Track track) async {
    final resolver = _artworkResolver;
    if (resolver == null || track.coverUri != null) return;
    try {
      final cover = await resolver.resolve(track);
      if (cover == null || request != _playRequest) return;
      if (state.track?.id != track.id) return;
      state = state.copyWith(track: track.copyWith(coverUri: cover));
    } on Object {
      // Best-effort artwork resolution; failures are not user-facing.
    }
  }

  /// 预 resolve 接下来的多首歌的 URL，形成滑动窗口。
  /// 后台/锁屏时 JSContext 可能失效，无法 resolve 新 URL。
  /// 通过预加载确保后台播放列表能连续播放，不需要调用 JSContext。
  /// 预加载数量设为 10，确保前台播放每首歌时提前缓存接下来 10 首的 URL，
  /// 配合后台单个 resolve 兜底，覆盖长播放列表的连续播放需求。
  static const _preloadCount = 10;

  Future<void> _prepareNextTrack() async {
    final tracks = _queue.state.tracks;
    if (tracks.isEmpty) return;
    final currentIndex = _queue.state.currentIndex;
    if (currentIndex < 0) return;
    // singleLoop 模式下下一首就是当前曲，URL 已缓存，不需要预加载其他歌曲。
    if (_queue.state.mode == PlaybackMode.singleLoop) return;
    // 先预 resolve peekAfterCompletion() 返回的下一首（考虑 shuffle），
    // 再按列表顺序预 resolve 接下来的几首。
    final upcoming = <Track>[];
    final peeked = _queue.peekAfterCompletion();
    if (peeked != null) upcoming.add(peeked);
    for (var offset = 1;
        offset <= _preloadCount && offset < tracks.length;
        offset++) {
      final index = (currentIndex + offset) % tracks.length;
      if (index == currentIndex) break;
      final track = tracks[index];
      if (upcoming.every((item) => item.id != track.id)) {
        upcoming.add(track);
      }
    }
    debugPrint('[BG] _prepareNextTrack: upcoming=${upcoming.length} '
        'ids=${upcoming.map((t) => t.id).join(",")}');
    // 记录启动时的当前曲目，resolve 循环中若当前曲目已变更则中止，
    // 避免 playTrack 已切换到新曲目时旧的预加载任务还在并发 resolve 同一首歌。
    final launchTrackId = state.track?.id;
    for (final track in upcoming) {
      if (track.sourceKind != TrackSourceKind.online) continue;
      // 若当前曲目已变更（playTrack 切到了新歌），中止剩余预加载。
      if (state.track?.id != launchTrackId) {
        debugPrint('[BG] _prepareNextTrack aborted: current track changed, '
            'expected=$launchTrackId actual=${state.track?.id}');
        return;
      }
      try {
        await _resolver.resolve(track, quality: _defaultQuality(track));
        debugPrint('[BG] _prepareNextTrack pre-resolved OK: id=${track.id}');
      } on Object catch (error) {
        debugPrint('[BG] _prepareNextTrack pre-resolve FAILED: id=${track.id} '
            'type=${error.runtimeType}');
        // 静默失败，后续歌曲继续预加载
      }
    }
  }

  /// 应用进入后台时调用，确保接下来几首歌的 URL 已缓存。
  ///
  /// 此时会顺带触发一次 _prepareNextTrack 预解析（此时音频仍在播放，
  /// audio session 活跃，JSContext 仍然有效），为进入后台后的前几首歌
  /// 提供缓冲。之后每首歌播放到剩余 30 秒时，_onSnapshot 会再次触发
  /// _prepareNextTrack，形成滑动窗口，保证后台无限连续播放。
  ///
  /// 注意：不能一次性并发 resolve 大量歌曲（之前尝试过 20 首并发，
  /// 触发 iOS 挂起整个 app）。这里依赖 _prepareNextTrack 的顺序 resolve
  /// （一次一首），安全可靠。
  void prepareForBackground() {
    if (_usingNativeOnline) return;
    final tracks = _queue.state.tracks;
    if (tracks.isEmpty) return;
    final currentIndex = _queue.state.currentIndex;
    if (currentIndex < 0) return;
    final count = tracks.length > 20 ? 20 : tracks.length;
    var cached = 0;
    var missing = 0;
    for (var offset = 1; offset < count; offset++) {
      final index = (currentIndex + offset) % tracks.length;
      if (index == currentIndex) break;
      final track = tracks[index];
      if (track.sourceKind != TrackSourceKind.online) continue;
      if (_resolver.getCachedUrl(track, quality: _defaultQuality(track)) !=
          null) {
        cached++;
      } else {
        missing++;
      }
    }
    debugPrint('[BG] prepareForBackground: queueSize=${tracks.length} '
        'currentIndex=$currentIndex cached=$cached missing=$missing');
    // 进入后台时音频仍在播放，JSContext 有效，触发一次预解析补充缓存。
    // 这与 _onSnapshot 中的"即将结束"预解析配合，确保切歌时 URL 已就绪。
    if (missing > 0) {
      debugPrint('[BG] prepareForBackground: triggering _prepareNextTrack '
          'while audio session still active');
      unawaited(_prepareNextTrack());
    }
  }

  Future<void> pause() async {
    if (_usingNativeOnline) {
      await _nativePlayback?.pause();
      return;
    }
    await _engine.pause();
    final track = state.track;
    if (track != null) _persistPosition(track, state.position, force: true);
  }

  Future<void> seek(Duration position) async {
    if (_usingNativeOnline) {
      await _nativePlayback?.seek(position);
      return;
    }
    // 记录 seek 目标 position，在 just_audio 报告接近目标的 position 之前，
    // _onSnapshot 会保留 state.position 为本目标值，避免旧 position 回退 UI。
    _seekTarget = position;
    _seekTargetReset?.cancel();
    // 兜底：5 秒后强制释放锁，避免 just_audio 永不报告接近目标 position
    // （例如 seek 失败、音源结束）时 UI 进度被永久锁死。
    _seekTargetReset = Timer(const Duration(seconds: 5), () {
      _seekTarget = null;
      _seekTargetReset = null;
    });
    await _engine.seek(position);
    final track = state.track;
    if (track == null) return;
    state = state.copyWith(position: position);
    _persistPosition(track, position, force: true);
  }

  Future<void> setSpeed(double speed) async {
    final normalized = speed.clamp(.5, 2.0).toDouble();
    await _engine.setSpeed(normalized);
    state = state.copyWith(speed: normalized);
  }

  Future<void> setVolume(double volume) async {
    final normalized = volume.clamp(0, 1).toDouble();
    await _engine.setVolume(normalized);
    state = state.copyWith(volume: normalized);
  }

  void setSleepTimer(Duration? duration) {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    if (duration == null) {
      state = state.copyWith(clearSleepTimer: true);
      return;
    }
    final endsAt = DateTime.now().add(duration);
    state = state.copyWith(
      sleepTimerEndsAt: endsAt,
      stopAfterCurrent: false,
    );
    _sleepTimer = Timer(duration, () => unawaited(_stopForSleepTimer()));
  }

  void setStopAfterCurrent(bool enabled) {
    if (enabled) {
      _sleepTimer?.cancel();
      _sleepTimer = null;
    }
    state = state.copyWith(
      stopAfterCurrent: enabled,
      clearSleepTimer: enabled,
    );
  }

  Future<void> _stopForSleepTimer() async {
    _sleepTimer = null;
    if (_usingNativeOnline) {
      await _nativePlayback?.stop();
    } else {
      await _engine.stop();
    }
    state = state.copyWith(
      clearSleepTimer: true,
      stopAfterCurrent: false,
    );
  }

  Future<void> setQuality(AudioQuality quality) {
    final track = state.track;
    if (track == null ||
        (track.sourceKind != TrackSourceKind.online &&
            !track.availableQualities.contains(quality))) {
      return Future.value();
    }
    return playTrack(
      track,
      quality: quality,
      initialPosition: state.position,
      autoPlay: state.isPlaying,
    );
  }

  void setDefaultQuality(AudioQuality quality) => _preferredQuality = quality;

  void _onSnapshot(AudioEngineSnapshot snapshot) {
    if (state.track != null && snapshot.track?.id != state.track?.id) return;
    if (snapshot.status == AudioEngineStatus.error && snapshot.track != null) {
      debugPrint('[BG] _onSnapshot error: id=${snapshot.track!.id} '
          'error=${snapshot.error} pos=${snapshot.position}');
      _handleEngineFailure(
        snapshot.track!,
        state.quality,
        AppFailure(
            code: AppFailureCode.unknown, message: snapshot.error ?? '音频播放失败'),
        initialPosition: snapshot.position,
      );
      return;
    }
    if (snapshot.status == AudioEngineStatus.completed &&
        snapshot.track?.id == state.track?.id) {
      debugPrint('[BG] _onSnapshot completed: id=${snapshot.track!.id} '
          'state.status=${state.status} pos=${snapshot.position}');
      if (state.status != AudioEngineStatus.playing) return;
      state = state.copyWith(
        position: snapshot.position,
        duration: snapshot.duration,
        status: AudioEngineStatus.completed,
      );
      _persistPosition(snapshot.track!, Duration.zero, force: true);
      if (state.stopAfterCurrent) {
        state = state.copyWith(
          stopAfterCurrent: false,
          clearSleepTimer: true,
        );
        unawaited(_engine.stop());
        return;
      }
      final nextTrack = _queue.selectAfterCompletion();
      debugPrint('[BG] _onSnapshot completed -> nextTrack: '
          'id=${nextTrack?.id} title=${nextTrack?.title}');
      if (nextTrack != null) {
        unawaited(playTrack(nextTrack));
        return;
      }
      // 队列已播放完毕，主动停止引擎以收敛到 idle 状态。
      // 否则引擎会停留在 completed，而 _emit 会把它上报为 loading，
      // 导致锁屏 UI 一直显示加载中且 iOS 后台音频会话无法正确释放。
      unawaited(_engine.stop());
      return;
    }
    final cueEnd = snapshot.track == null ? null : _cueEnd(snapshot.track!);
    if (snapshot.status == AudioEngineStatus.playing &&
        state.status == AudioEngineStatus.playing &&
        snapshot.track?.id == state.track?.id &&
        cueEnd != null &&
        snapshot.position >= cueEnd) {
      debugPrint('[BG] _onSnapshot cue-end reached: id=${snapshot.track!.id} '
          'pos=${snapshot.position} cueEnd=$cueEnd');
      state = state.copyWith(
        position: snapshot.position,
        duration: snapshot.duration,
        status: AudioEngineStatus.completed,
      );
      final nextTrack = _queue.selectAfterCompletion();
      debugPrint('[BG] _onSnapshot cue-end -> nextTrack: '
          'id=${nextTrack?.id} title=${nextTrack?.title}');
      if (nextTrack != null) {
        unawaited(playTrack(nextTrack));
      } else {
        unawaited(_engine.stop());
      }
      return;
    }
    if (snapshot.status == AudioEngineStatus.playing &&
        snapshot.track != null &&
        _recordedHistoryTrackId != snapshot.track!.id) {
      _recordedHistoryTrackId = snapshot.track!.id;
      _recordHistory(snapshot.track!, snapshot.position);
    } else if (snapshot.track != null &&
        (snapshot.status == AudioEngineStatus.playing ||
            snapshot.status == AudioEngineStatus.paused)) {
      _persistPosition(
        snapshot.track!,
        snapshot.position,
        force: snapshot.status == AudioEngineStatus.paused,
      );
    }
    // 后台连续播放核心：歌曲即将结束时（剩余 30 秒）提前预解析接下来的歌曲。
    // 此时 audio session 活跃、JSContext 有效，预解析能成功完成。
    // 切歌时（completed → loading）JSContext 可能被 iOS 回收，此时再解析会失败。
    // 通过提前预解析，切歌时直接使用缓存的 URL，无需调用 JSContext。
    if (snapshot.status == AudioEngineStatus.playing &&
        snapshot.track != null &&
        snapshot.duration != null &&
        _preloadedForCompletionTrackId != snapshot.track!.id) {
      final remaining = snapshot.duration! - snapshot.position;
      if (remaining <= _preloadBeforeEndThreshold) {
        final trackId = snapshot.track!.id;
        _preloadedForCompletionTrackId = trackId;
        debugPrint('[BG] _onSnapshot preloading before completion: '
            'id=$trackId remaining=${remaining.inSeconds}s');
        unawaited(_prepareNextTrack());
      }
    }
    // 拖动进度条后，just_audio 的 positionStream 可能在 seek 完成前仍 emit 旧 position。
    // 此时 _seekTarget != null 且 snapshot.position 与目标差距较大，
    // 应保留 state.position 为 _seekTarget，避免 UI 进度回退。
    // 当 snapshot.position 接近 _seekTarget（差值 <= 1 秒）时认为 seek 已生效，
    // 清除 _seekTarget 并恢复正常的 position 同步。
    final effectivePosition = _resolveEffectivePosition(snapshot.position);
    state = PlayerState(
      track: snapshot.track,
      position: effectivePosition,
      duration: snapshot.duration,
      status: snapshot.status,
      speed: state.speed,
      volume: state.volume,
      quality: state.quality,
      sleepTimerEndsAt: state.sleepTimerEndsAt,
      stopAfterCurrent: state.stopAfterCurrent,
      fileInfo: state.fileInfo,
      error: snapshot.error == null
          ? null
          : AppFailure(code: AppFailureCode.unknown, message: snapshot.error!),
    );
  }

  /// 根据当前 _seekTarget 决定 _onSnapshot 中使用的 effective position。
  /// - 若 _seekTarget 为空：正常返回 snapshot.position
  /// - 若 snapshot.position 与 _seekTarget 接近（<= 1 秒）：seek 已生效，清除目标，返回 snapshot.position
  /// - 若差距较大：返回 _seekTarget 避免 UI 进度回退
  Duration _resolveEffectivePosition(Duration snapshotPosition) {
    final target = _seekTarget;
    if (target == null) return snapshotPosition;
    final delta = (snapshotPosition - target).abs();
    if (delta <= const Duration(seconds: 1)) {
      _clearSeekTarget();
      return snapshotPosition;
    }
    return target;
  }

  void _clearSeekTarget() {
    _seekTarget = null;
    _seekTargetReset?.cancel();
    _seekTargetReset = null;
  }

  void _onEngineCommand(AudioEngineCommand command) {
    if (_usingNativeOnline) {
      switch (command) {
        case AudioEngineCommand.next:
          unawaited(_nativePlayback?.next());
        case AudioEngineCommand.previous:
          unawaited(_nativePlayback?.previous());
      }
      return;
    }
    switch (command) {
      case AudioEngineCommand.next:
        final next = _queue.selectNext();
        if (next != null) unawaited(playTrack(next));
      case AudioEngineCommand.previous:
        final previous = _queue.selectPrevious();
        if (previous != null) unawaited(playTrack(previous));
    }
  }

  Future<void> _probeFileInfo(int request, Uri uri) async {
    final info = await _fileProbe.probe(uri);
    if (request != _playRequest) return;
    state = state.copyWith(fileInfo: info);
  }

  void _recordHistory(Track track, Duration position) => _queueHistoryWrite(
        () => _library.recordHistory(track, position),
      );

  void _persistPosition(Track track, Duration position, {bool force = false}) {
    final sameTrack = _lastPersistedTrackId == track.id;
    final difference = position - _lastPersistedPosition;
    if (!force && sameTrack && difference.abs() < _positionCheckpoint) return;
    _lastPersistedTrackId = track.id;
    _lastPersistedPosition = position;
    _updateHistoryPosition(track.id, position);
  }

  void _updateHistoryPosition(String trackId, Duration position) =>
      _queueHistoryWrite(
        () => _library.updateHistoryPosition(trackId, position),
      );

  void _queueHistoryWrite(Future<void> Function() write) {
    _historyWrites = _historyWrites
        .then((_) => write())
        .onError((Object error, StackTrace stackTrace) {
      // ponytail: history is non-critical; surface storage failures stay in Library UI.
    });
  }

  void _handleEngineFailure(
    Track track,
    AudioQuality quality,
    AppFailure error, {
    Duration? initialPosition,
    bool autoPlay = true,
  }) {
    debugPrint('[BG] _handleEngineFailure: id=${track.id} quality=$quality '
        'code=${error.code} message=${error.message}');
    if (!_handledEngineFailures.add(_engineFailureKey(track, quality))) {
      debugPrint(
          '[BG] _handleEngineFailure already handled, skip: id=${track.id}');
      return;
    }
    if (_refreshedTrackQualities.add('${track.id}:${quality.name}')) {
      debugPrint(
          '[BG] _handleEngineFailure retry with fresh URL: id=${track.id}');
      _resolver.invalidate(track, quality: quality);
      unawaited(
        playTrack(
          track,
          quality: quality,
          retryFailed: false,
          refreshUrl: true,
          initialPosition: initialPosition,
          autoPlay: autoPlay,
        ),
      );
      return;
    }
    // A transport failure says nothing about availability of the selected
    // quality. Downgrading here turns a locked-screen transient into silent
    // data loss, so retain the requested quality and surface the failure.
    _failStrictQuality(track, error);
  }

  String _engineFailureKey(Track track, AudioQuality quality) =>
      '${track.id}:${quality.name}';

  void _handleResolveFailure(
    Track track,
    AudioQuality quality,
    AppFailure error, {
    Duration? initialPosition,
    bool autoPlay = true,
  }) {
    debugPrint('[BG] _handleResolveFailure: id=${track.id} quality=$quality '
        'code=${error.code} message=${error.message}');
    _failStrictQuality(track, error);
  }

  void _failStrictQuality(Track track, AppFailure error) {
    _failedTrackIds.add(track.id);
    unawaited(_engine.stop());
    state = state.copyWith(status: AudioEngineStatus.error, error: error);
  }

  AudioQuality _defaultQuality(Track track) =>
      preferredPlaybackQuality(track.availableQualities, _preferredQuality);

  Duration? _validResumePosition(Track track, Duration? position) {
    if (position == null || position < const Duration(seconds: 5)) return null;
    final duration = track.duration;
    if (duration != null && position >= duration - const Duration(seconds: 3)) {
      return null;
    }
    return position;
  }

  Duration? _cueStart(Track track) => _cueMarker(track, 'cueStartMs');

  Duration? _cueEnd(Track track) => _cueMarker(track, 'cueEndMs');

  Duration? _cueMarker(Track track, String key) => switch (track.extra[key]) {
        final int milliseconds => Duration(milliseconds: milliseconds),
        final num milliseconds => Duration(milliseconds: milliseconds.toInt()),
        _ => null,
      };

  @override
  void dispose() {
    _sleepTimer?.cancel();
    _seekTargetReset?.cancel();
    _subscription.cancel();
    _engineCommandSubscription.cancel();
    _seekSubscription.cancel();
    _nativeStateSubscription?.cancel();
    super.dispose();
  }
}
