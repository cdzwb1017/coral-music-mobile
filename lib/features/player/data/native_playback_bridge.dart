import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../../core/app_failure.dart';
import '../../../domain/music.dart';
import 'audio_engine.dart';
import 'user_api_runner.dart';

/// Native online queue owner. It deliberately transports logical tracks, never
/// a resolved CDN URL, so the platform can refresh expiring URLs itself.
final class NativePlaybackBridge {
  NativePlaybackBridge() {
    _events.receiveBroadcastStream().listen(
          (event) => _eventController.add(NativePlaybackState.fromEvent(event)),
          onError: _eventController.addError,
        );
  }

  static const _methods = MethodChannel('coral_music/native_playback');
  static const _events = EventChannel('coral_music/native_playback_events');
  final _eventController = StreamController<NativePlaybackState>.broadcast();

  Stream<NativePlaybackState> get states => _eventController.stream;

  bool get supportsOnlineQueue =>
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android;

  Future<void> startQueue({
    required List<Track> tracks,
    required int index,
    required PlaybackMode mode,
    required AudioQuality quality,
    required bool autoPlay,
  }) =>
      _call('startQueue', {
        'tracks': tracks.map((track) => _track(track, quality)).toList(),
        'index': index,
        'mode': mode.name,
        'quality': _qualityName(quality),
        'autoPlay': autoPlay,
      });

  Future<void> play() => _call('play');
  Future<void> pause() => _call('pause');
  Future<void> stop() => _call('stop');
  Future<void> next() => _call('next');
  Future<void> previous() => _call('previous');
  Future<void> seek(Duration position) =>
      _call('seek', {'positionMs': position.inMilliseconds});

  Future<void> _call(String method,
      [Map<String, Object?> arguments = const {}]) async {
    try {
      await _methods.invokeMethod<void>(method, arguments);
    } on PlatformException catch (error) {
      throw AppFailure(
        code: AppFailureCode.unknown,
        message: error.message ?? '原生后台播放失败',
        diagnostic: error.code,
      );
    } on MissingPluginException {
      throw const AppFailure(
        code: AppFailureCode.invalidData,
        message: '当前平台未启用原生后台播放',
      );
    }
  }

  Map<String, Object?> _track(Track track, AudioQuality quality) => {
        'id': track.id,
        'source': track.sourceId,
        'quality': _qualityName(quality),
        'title': track.title,
        'artist': track.artist,
        'album': track.album,
        'durationMs': track.duration?.inMilliseconds,
        'artwork': track.coverUri?.toString(),
        'musicInfo': MethodChannelUserApiRunner.legacyMusicInfo(track),
      };

  static String _qualityName(AudioQuality quality) => switch (quality) {
        AudioQuality.flac24bit => 'flac24bit',
        AudioQuality.flac => 'flac',
        AudioQuality.high320k => '320k',
        AudioQuality.high192k => '192k',
        AudioQuality.standard128k => '128k',
        AudioQuality.hires => 'hires',
        AudioQuality.atmos => 'atmos',
        AudioQuality.atmosPlus => 'atmos_plus',
        AudioQuality.master => 'master',
      };

  Future<void> dispose() => _eventController.close();
}

final class NativePlaybackState {
  const NativePlaybackState({
    required this.index,
    required this.status,
    this.position = Duration.zero,
    this.duration,
    this.quality,
    this.bitrate,
    this.sampleRate,
    this.error,
  });

  factory NativePlaybackState.fromEvent(Object? raw) {
    final map = raw is Map ? raw : const <Object?, Object?>{};
    final status = switch (map['status']) {
      'loading' => AudioEngineStatus.loading,
      'ready' => AudioEngineStatus.ready,
      'playing' => AudioEngineStatus.playing,
      'paused' => AudioEngineStatus.paused,
      'completed' => AudioEngineStatus.completed,
      'error' => AudioEngineStatus.error,
      _ => AudioEngineStatus.idle,
    };
    final durationMs = map['durationMs'];
    return NativePlaybackState(
      index: map['index'] is int ? map['index'] as int : -1,
      status: status,
      position:
          Duration(milliseconds: (map['positionMs'] as num? ?? 0).toInt()),
      duration:
          durationMs is num ? Duration(milliseconds: durationMs.toInt()) : null,
      quality: map['quality'] as String?,
      bitrate: (map['bitrate'] as num?)?.toInt(),
      sampleRate: (map['sampleRate'] as num?)?.toInt(),
      error: map['error'] as String?,
    );
  }

  final int index;
  final AudioEngineStatus status;
  final Duration position;
  final Duration? duration;
  final String? quality;
  final int? bitrate;
  final int? sampleRate;
  final String? error;
}
