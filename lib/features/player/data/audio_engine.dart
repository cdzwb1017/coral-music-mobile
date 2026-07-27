import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';

import '../../../domain/music.dart';
import 'dsd_audio_stream.dart';

enum AudioEngineStatus {
  idle,
  loading,
  ready,
  playing,
  paused,
  completed,
  error
}

enum AudioEngineCommand { next, previous }

final class AudioEngineSnapshot {
  const AudioEngineSnapshot({
    this.track,
    this.position = Duration.zero,
    this.duration,
    this.status = AudioEngineStatus.idle,
    this.error,
  });

  final Track? track;
  final Duration position;
  final Duration? duration;
  final AudioEngineStatus status;
  final String? error;

  bool get isPlaying => status == AudioEngineStatus.playing;
}

abstract interface class AudioEngine {
  Stream<AudioEngineSnapshot> get snapshots;
  Stream<AudioEngineCommand> get commands;
  /// 外部（锁屏/控制中心）seek 事件流。
  /// PlayerController 监听此流以同步 _seekTarget，避免 UI 进度与真实播放不一致。
  Stream<Duration> get seeks;

  Future<void> load(Track track, Uri uri, {Map<String, String> headers});
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> setSpeed(double speed);
  Future<void> setVolume(double volume);
  Future<void> stop();
  Future<void> dispose();
}

final class JustAudioEngine implements AudioEngine {
  Future<_CoralAudioHandler>? _handler;
  final _snapshots = StreamController<AudioEngineSnapshot>.broadcast();
  final _commands = StreamController<AudioEngineCommand>.broadcast();
  final _seeks = StreamController<Duration>.broadcast();
  StreamSubscription<AudioEngineSnapshot>? _snapshotSubscription;
  StreamSubscription<AudioEngineCommand>? _commandSubscription;
  StreamSubscription<Duration>? _seekSubscription;

  @override
  Stream<AudioEngineSnapshot> get snapshots => _snapshots.stream;

  @override
  Stream<AudioEngineCommand> get commands => _commands.stream;

  @override
  Stream<Duration> get seeks => _seeks.stream;

  @override
  Future<void> load(Track track, Uri uri,
      {Map<String, String> headers = const {}}) async {
    await (await _getHandler()).load(track, uri, headers: headers);
  }

  @override
  Future<void> play() async => (await _getHandler()).play();

  @override
  Future<void> pause() async => (await _getHandler()).pause();

  @override
  Future<void> seek(Duration position) async =>
      (await _getHandler()).seek(position);

  @override
  Future<void> setSpeed(double speed) async =>
      (await _getHandler()).setSpeed(speed);

  @override
  Future<void> setVolume(double volume) async =>
      (await _getHandler()).setVolume(volume);

  @override
  Future<void> stop() async => (await _getHandler()).stop();

  @override
  Future<void> dispose() async {
    final handler = _handler;
    _handler = null;
    await _snapshotSubscription?.cancel();
    await _commandSubscription?.cancel();
    await _seekSubscription?.cancel();
    try {
      if (handler != null) await (await handler).dispose();
    } finally {
      await _setBackgroundMediaEnabled(false);
      await _snapshots.close();
      await _commands.close();
      await _seeks.close();
    }
  }

  Future<_CoralAudioHandler> _getHandler() async {
    final future = _handler ??= _createHandler();
    try {
      final handler = await future;
      _snapshotSubscription ??= handler.snapshots.listen(
        _snapshots.add,
        onError: (_, __) => _snapshots.add(const AudioEngineSnapshot(
          status: AudioEngineStatus.error,
          error: '音频播放失败',
        )),
      );
      _commandSubscription ??= handler.commands.listen(_commands.add);
      _seekSubscription ??= handler.seeks.listen(_seeks.add);
      return handler;
    } on Object {
      if (identical(_handler, future)) _handler = null;
      rethrow;
    }
  }
}

Future<_CoralAudioHandler> _createHandler() async {
  var backgroundMediaEnabled = false;
  try {
    await _setBackgroundMediaEnabled(true);
    backgroundMediaEnabled = true;
    final handler = await AudioService.init(
      builder: _CoralAudioHandler.new,
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.coral.music.mobile.playback',
        androidNotificationChannelName: '珊瑚音乐播放',
      ),
    );
    await (await AudioSession.instance)
        .configure(AudioSessionConfiguration.music());
    return handler;
  } on MissingPluginException {
    if (backgroundMediaEnabled) await _setBackgroundMediaEnabled(false);
    // ponytail: Harmony falls back to its just_audio implementation until audio_service gains an OHOS backend.
    return _CoralAudioHandler();
  } on Object {
    if (backgroundMediaEnabled) await _setBackgroundMediaEnabled(false);
    rethrow;
  }
}

const _backgroundMediaChannel = MethodChannel('coral_music/background_media');

Future<void> _setBackgroundMediaEnabled(bool enabled) async {
  try {
    await _backgroundMediaChannel.invokeMethod<void>(
      'setBackgroundMediaEnabled',
      {'enabled': enabled},
    );
  } on MissingPluginException {
    // ponytail: only Android needs a manifest receiver; other platforms own their media route.
  }
}

final class _CoralAudioHandler extends BaseAudioHandler with SeekHandler {
  _CoralAudioHandler() {
    _subscriptions.add(_player.playerStateStream.listen((value) {
      _emit(status: _statusOf(value));
    }));
    _subscriptions
        .add(_player.positionStream.listen((value) => _emit(position: value)));
    _subscriptions
        .add(_player.durationStream.listen((value) => _emit(duration: value)));
    _subscriptions.add(_player.errorStream.listen((error) {
      debugPrint('[BG] just_audio errorStream: $error');
      _emit(status: AudioEngineStatus.error, error: '音频播放失败');
    }));
  }

  final _player = AudioPlayer();
  final _snapshots = StreamController<AudioEngineSnapshot>.broadcast();
  final _commands = StreamController<AudioEngineCommand>.broadcast();
  // 外部（锁屏/控制中心）seek 事件流。
  // SeekHandler.seek 在锁屏拖动进度条时被调用，通过此流通知 PlayerController
  // 同步 _seekTarget，避免 just_audio 的 positionStream 在 seek 完成前 emit 旧
  // position 导致 UI 进度回退。
  final _seeks = StreamController<Duration>.broadcast();
  final _subscriptions = <StreamSubscription<Object?>>[];
  FfmpegAudioStream? _ffmpegStream;
  AudioEngineSnapshot _snapshot = const AudioEngineSnapshot();

  Stream<AudioEngineSnapshot> get snapshots => _snapshots.stream;
  Stream<AudioEngineCommand> get commands => _commands.stream;
  Stream<Duration> get seeks => _seeks.stream;

  Future<void> load(Track track, Uri uri,
      {Map<String, String> headers = const {}}) async {
    await _closeFfmpegStream();
    _snapshot =
        AudioEngineSnapshot(track: track, status: AudioEngineStatus.loading);
    _snapshots.add(_snapshot);
    FfmpegAudioStream? stream;
    final playableUri = await recoverIosSandboxDocumentUri(uri);
    mediaItem.add(MediaItem(
      id: uri.toString(),
      title: track.title,
      artist: track.artist,
      album: track.album,
      duration: track.duration,
      artUri: track.coverUri,
    ));
    // 后台切换音轨时 iOS 可能 deactivate AVAudioSession（PlayerRemoteXPC 错误），
    // 导致新 AVPlayerItem 加载立即失败（-11849 Operation Stopped）。
    // load 前主动 setActive(true) 确保音频会话活跃。
    await _ensureAudioSessionActive();
    try {
      stream = await FfmpegAudioStream.open(playableUri);
      debugPrint('[BG] engine.load setAudioSource: uri=${stream?.uri ?? playableUri} '
          'headers=${headers.isEmpty ? "none" : headers.keys.join(",")} '
          'ffmpegStream=${stream != null}');
      await _player.setAudioSource(
        AudioSource.uri(stream?.uri ?? playableUri, headers: headers),
      );
      _ffmpegStream = stream;
    } on Object catch (error, stack) {
      debugPrint('[BG] engine.load FAILED: type=${error.runtimeType} '
          'error=$error');
      debugPrint('[BG] engine.load stack: $stack');
      await stream?.dispose();
      rethrow;
    }
    _emit(track: track, status: AudioEngineStatus.ready, error: null);
  }

  /// 确保 AVAudioSession 处于活跃状态。
  /// 后台切换音轨时系统可能 deactivate 音频会话，导致 AVPlayerItem 加载失败。
  Future<void> _ensureAudioSessionActive() async {
    try {
      final session = await AudioSession.instance;
      // setActive(true) 会重新激活 AVAudioSession，恢复 PlayerRemoteXPC 连接。
      await session.setActive(true);
    } on Object catch (error) {
      debugPrint('[BG] _ensureAudioSessionActive failed: ${error.runtimeType}');
    }
  }

  @override
  Future<void> play() async {
    // 后台 completed → load → play 链路中，AVPlayer 可能因 AVAudioSession 被
    // deactivate 或 PlayerRemoteXPC 连接断开而无法播放（_player.rate 设置不生效），
    // 但 just_audio 的 _playing 标志已置为 YES，导致 state 显示 playing 却没声音
    // （虚假播放）。play 前主动 setActive(true) 恢复音频会话。
    await _ensureAudioSessionActive();
    // processingState 为 idle 时 play 不会生效，直接报错避免虚假播放。
    if (_player.processingState == ProcessingState.idle) {
      debugPrint('[BG] play aborted: processingState=idle');
      _emit(status: AudioEngineStatus.error, error: '音频播放失败');
      return;
    }
    _emit(status: AudioEngineStatus.playing, error: null);
    unawaited(_player.play().catchError((Object _, StackTrace __) {
      _emit(status: AudioEngineStatus.error, error: '音频播放失败');
    }));
  }

  @override
  Future<void> pause() async {
    await _player.pause();
    _emit(status: AudioEngineStatus.paused);
  }

  @override
  Future<void> seek(Duration position) async {
    await _player.seek(position);
    // 通知 PlayerController 同步 _seekTarget，避免 just_audio 的 positionStream
    // 在 seek 完成前 emit 旧 position 导致 UI 进度回退。
    _seeks.add(position);
  }

  @override
  Future<void> setSpeed(double speed) => _player.setSpeed(speed);

  Future<void> setVolume(double volume) => _player.setVolume(volume);

  @override
  Future<void> skipToNext() async => _commands.add(AudioEngineCommand.next);

  @override
  Future<void> skipToPrevious() async =>
      _commands.add(AudioEngineCommand.previous);

  @override
  Future<void> stop() async {
    await _player.stop();
    await _closeFfmpegStream();
    _emit(status: AudioEngineStatus.idle);
    await super.stop();
  }

  Future<void> dispose() async {
    try {
      await stop();
    } finally {
      await Future.wait(_subscriptions.map((item) => item.cancel()));
      await _player.dispose();
      await _snapshots.close();
      await _commands.close();
      await _seeks.close();
    }
  }

  Future<void> _closeFfmpegStream() async {
    final stream = _ffmpegStream;
    _ffmpegStream = null;
    await stream?.dispose();
  }

  void _emit(
      {Track? track,
      Duration? position,
      Duration? duration,
      AudioEngineStatus? status,
      String? error}) {
    _snapshot = AudioEngineSnapshot(
      track: track ?? _snapshot.track,
      position: position ?? _snapshot.position,
      duration: duration ?? _snapshot.duration,
      status: status ?? _snapshot.status,
      error: error,
    );
    _snapshots.add(_snapshot);
    // iOS 后台音频会话要求 AVAudioSession 保持活跃才不会挂起应用。
    // audio_service 在 playing: false 时会 deactivate AVAudioSession，
    // 导致 iOS 挂起应用，JSContext/URLSession/main RunLoop 全部冻结。
    // 只有用户主动暂停 (paused) 或完全停止 (idle) 时才上报 playing: false，
    // 其他状态（loading/ready/completed/playing/error）都保持 playing: true，
    // 确保从 completed → resolve → load → play 整个链路 AVAudioSession 活跃。
    final audioServicePlaying = _snapshot.status != AudioEngineStatus.paused &&
        _snapshot.status != AudioEngineStatus.idle;
    playbackState.add(PlaybackState(
      controls: audioServicePlaying
          ? const [
              MediaControl.skipToPrevious,
              MediaControl.pause,
              MediaControl.skipToNext,
            ]
          : const [
              MediaControl.skipToPrevious,
              MediaControl.play,
              MediaControl.skipToNext,
            ],
      systemActions: const {MediaAction.seek},
      androidCompactActionIndices: const [0, 1, 2],
      processingState: switch (_snapshot.status) {
        AudioEngineStatus.idle => AudioProcessingState.idle,
        AudioEngineStatus.loading => AudioProcessingState.loading,
        AudioEngineStatus.completed => AudioProcessingState.loading,
        AudioEngineStatus.error => AudioProcessingState.error,
        _ => AudioProcessingState.ready,
      },
      playing: audioServicePlaying,
      updatePosition: _snapshot.position,
      speed: _player.speed,
    ));
  }

  AudioEngineStatus _statusOf(PlayerState state) =>
      switch (state.processingState) {
        ProcessingState.idle => AudioEngineStatus.idle,
        ProcessingState.loading ||
        ProcessingState.buffering =>
          AudioEngineStatus.loading,
        ProcessingState.ready =>
          state.playing ? AudioEngineStatus.playing : AudioEngineStatus.paused,
        ProcessingState.completed => AudioEngineStatus.completed,
      };
}
