import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_failure.dart';
import '../../../domain/music.dart';
import '../data/library_store.dart';
import '../data/library_backup_codec.dart';
import '../data/local_audio_scanner.dart';
import '../data/lx_sync_service.dart';
import '../data/playlist_transfer_codec.dart';

final libraryProvider = StateNotifierProvider<LibraryController, LibraryState>(
  (ref) => LibraryController(ref.watch(libraryStoreProvider)),
);

final class LibraryState {
  const LibraryState({
    this.playlists = const [],
    this.selectedPlaylist,
    this.tracks = const [],
    this.favoriteOnlinePlaylists = const [],
    this.favoriteAlbums = const [],
    this.favoriteRevision = 0,
    this.playlistFavoriteRevision = 0,
    this.isLoading = false,
    this.error,
  });

  final List<UserPlaylist> playlists;
  final UserPlaylist? selectedPlaylist;
  final List<Track> tracks;
  final List<PlaylistDetail> favoriteOnlinePlaylists;
  final List<FavoriteAlbum> favoriteAlbums;
  final int favoriteRevision;
  final int playlistFavoriteRevision;
  final bool isLoading;
  final AppFailure? error;

  LibraryState copyWith({
    List<UserPlaylist>? playlists,
    UserPlaylist? selectedPlaylist,
    List<Track>? tracks,
    List<PlaylistDetail>? favoriteOnlinePlaylists,
    List<FavoriteAlbum>? favoriteAlbums,
    int? favoriteRevision,
    int? playlistFavoriteRevision,
    bool? isLoading,
    AppFailure? error,
    bool clearError = false,
    bool clearSelectedPlaylist = false,
  }) =>
      LibraryState(
        playlists: playlists ?? this.playlists,
        selectedPlaylist: clearSelectedPlaylist
            ? null
            : selectedPlaylist ?? this.selectedPlaylist,
        tracks: clearSelectedPlaylist ? const [] : tracks ?? this.tracks,
        favoriteOnlinePlaylists:
            favoriteOnlinePlaylists ?? this.favoriteOnlinePlaylists,
        favoriteAlbums: favoriteAlbums ?? this.favoriteAlbums,
        favoriteRevision: favoriteRevision ?? this.favoriteRevision,
        playlistFavoriteRevision:
            playlistFavoriteRevision ?? this.playlistFavoriteRevision,
        isLoading: isLoading ?? this.isLoading,
        error: clearError ? null : error ?? this.error,
      );
}

final class LibraryController extends StateNotifier<LibraryState> {
  LibraryController(this._store) : super(const LibraryState());

  final LibraryStore _store;

  Future<void> load() => _run(() async {
        state = state.copyWith(
          playlists: await _store.listPlaylists(),
          isLoading: false,
          clearError: true,
        );
      });

  Future<void> create(String name) => _run(() async {
        await _store.createPlaylist(name);
        state = state.copyWith(
          playlists: await _store.listPlaylists(),
          isLoading: false,
          clearError: true,
        );
      });

  Future<({UserPlaylist playlist, int added, int skipped})?> importPlaylist(
    String raw,
  ) async {
    if (state.isLoading) return null;
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final result =
          await _store.importPlaylist(PlaylistTransferCodec.decode(raw));
      state = state.copyWith(
        playlists: await _store.listPlaylists(),
        isLoading: false,
        clearError: true,
      );
      return result;
    } on FormatException catch (error) {
      state = state.copyWith(
        isLoading: false,
        error: AppFailure(
          code: AppFailureCode.invalidData,
          message: error.message,
        ),
      );
      return null;
    } on Object catch (error) {
      state = state.copyWith(
        isLoading: false,
        error: AppFailure(
          code: AppFailureCode.unknown,
          message: '导入列表失败',
          diagnostic: error.runtimeType.toString(),
        ),
      );
      return null;
    }
  }

  Future<String> exportPlaylist(UserPlaylist playlist) =>
      _store.exportPlaylist(playlist);

  LibraryBackup previewLibraryBackup(String raw) =>
      LibraryBackupCodec.decode(raw);

  Future<({int playlists, int tracks, int favorites, int ignored})?>
      restoreLibraryBackup(LibraryBackup backup) async {
    if (state.isLoading) return null;
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final result = await _store.restoreLibraryBackup(backup);
      state = state.copyWith(
        playlists: await _store.listPlaylists(),
        isLoading: false,
        clearError: true,
      );
      return result;
    } on Object catch (error) {
      state = state.copyWith(
        isLoading: false,
        error: AppFailure(
          code: AppFailureCode.unknown,
          message: '恢复备份失败，现有资料未被修改',
          diagnostic: error.runtimeType.toString(),
        ),
      );
      return null;
    }
  }

  Future<String> exportLibraryBackup() => _store.exportLibraryBackup();

  Future<({int playlists, int tracks, int favorites})?> importLxSnapshot(
    LxSyncSnapshot snapshot,
  ) async {
    if (state.isLoading) return null;
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      var created = 0;
      var tracks = 0;
      var favorites = 0;
      var playlists = await _store.listPlaylists();
      var favoritePlaylists = 0;

      Future<void> merge(String name, List<Track> source) async {
        if (source.isEmpty) return;
        final target =
            playlists.where((item) => item.name == name).firstOrNull ??
                await _store.createPlaylist(name);
        if (!playlists.any((item) => item.id == target.id)) {
          playlists = [...playlists, target];
          created++;
        }
        for (final track in source) {
          if (await _store.addTrack(target.id, track)) tracks++;
        }
      }

      await merge('落雪 · 默认列表', snapshot.defaultTracks);
      for (final playlist in snapshot.playlists) {
        await merge('落雪 · ${playlist.name}', playlist.tracks);
        if (playlist.tracks.isNotEmpty) {
          final first = playlist.tracks.first;
          final source = OnlineSource.values.firstWhere(
            (candidate) => candidate.id == first.sourceId,
            orElse: () => OnlineSource.netease,
          );
          final detail = PlaylistDetail(
            playlist: OnlinePlaylist(
              id: 'lx-${playlist.name.trim().toLowerCase()}',
              source: source,
              name: playlist.name,
              trackCount: playlist.tracks.length,
              coverUri: first.coverUri,
            ),
            tracks: playlist.tracks,
          );
          if (await _store.addFavoriteOnlinePlaylist(detail)) {
            favoritePlaylists++;
          }
        }
      }
      for (final track in snapshot.favoriteTracks) {
        if (!await _store.isFavorite(track.id)) {
          await _store.toggleFavorite(track);
          favorites++;
        }
      }
      final albumTracks = <String, List<Track>>{};
      for (final track in [
        ...snapshot.favoriteTracks,
        ...snapshot.defaultTracks,
        ...snapshot.playlists.expand((playlist) => playlist.tracks),
      ]) {
        final album = track.album?.trim() ?? '';
        if (album.isEmpty) continue;
        albumTracks.putIfAbsent('${track.sourceId}:$album', () => []).add(track);
      }
      for (final entry in albumTracks.entries) {
        final albumName = entry.key.substring(entry.key.indexOf(':') + 1);
        await _store.addFavoriteAlbum(albumName, entry.value);
      }
      state = state.copyWith(
        playlists: await _store.listPlaylists(),
        favoriteOnlinePlaylists: await _store.listFavoriteOnlinePlaylists(),
        favoriteAlbums: await _store.listFavoriteAlbums(),
        favoriteRevision: state.favoriteRevision + (favorites == 0 ? 0 : 1),
        playlistFavoriteRevision:
            state.playlistFavoriteRevision + (favoritePlaylists == 0 ? 0 : 1),
        isLoading: false,
        clearError: true,
      );
      return (playlists: created, tracks: tracks, favorites: favorites);
    } on Object catch (error) {
      state = state.copyWith(
        isLoading: false,
        error: AppFailure(
          code: AppFailureCode.unknown,
          message: '落雪列表合并失败，请重试',
          diagnostic: error.runtimeType.toString(),
        ),
      );
      return null;
    }
  }

  Future<void> rename(UserPlaylist playlist, String name) => _run(() async {
        await _store.renamePlaylist(playlist, name);
        state = state.copyWith(
          playlists: await _store.listPlaylists(),
          isLoading: false,
          clearError: true,
        );
      });

  Future<void> delete(String id) => _run(() async {
        await _store.deletePlaylist(id);
        state = state.copyWith(
          playlists: await _store.listPlaylists(),
          isLoading: false,
          clearError: true,
        );
      });

  Future<void> open(UserPlaylist playlist) => _run(() async {
        state = state.copyWith(
          selectedPlaylist: playlist,
          tracks: await _store.listTracks(playlist.id),
          isLoading: false,
          clearError: true,
        );
      });

  Future<void> openFavorites() => _run(() async {
        state = state.copyWith(
          selectedPlaylist: UserPlaylist(
            id: LibraryStore.favoritesId,
            name: '我的收藏',
            position: -1,
            createdAt: DateTime.fromMillisecondsSinceEpoch(0),
            updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
          ),
          tracks: await _store.listFavorites(),
          favoriteOnlinePlaylists: await _store.listFavoriteOnlinePlaylists(),
          favoriteAlbums: await _store.listFavoriteAlbums(),
          isLoading: false,
          clearError: true,
        );
      }, force: true);

  void close() => state = state.copyWith(clearSelectedPlaylist: true);

  Future<bool> addTrack(UserPlaylist playlist, Track track) async {
    if (state.isLoading) return false;
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final added = await _store.addTrack(playlist.id, track);
      state = state.copyWith(
        tracks: state.selectedPlaylist?.id == playlist.id
            ? await _store.listTracks(playlist.id)
            : null,
        isLoading: false,
        clearError: true,
      );
      return added;
    } on Object catch (error) {
      state = state.copyWith(
        isLoading: false,
        error: AppFailure(
          code: AppFailureCode.unknown,
          message: '歌曲加入列表失败',
          diagnostic: error.runtimeType.toString(),
        ),
      );
      return false;
    }
  }

  Future<({int added, int skipped})?> importSharedAudio(
    List<String> paths, {
    String playlistName = '分享导入',
    bool openPlaylist = false,
  }) async {
    if (paths.isEmpty || state.isLoading) return null;
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final scan = await LocalAudioScanner().scanFiles(paths);
      if (scan.tracks.isEmpty) {
        state = state.copyWith(isLoading: false, clearError: true);
        return (added: 0, skipped: scan.skipped.length);
      }
      final playlists = await _store.listPlaylists();
      final target =
          playlists.where((item) => item.name == playlistName).firstOrNull ??
              await _store.createPlaylist(playlistName);
      var added = 0;
      for (final track in scan.tracks) {
        if (await _store.addTrack(target.id, track)) added++;
      }
      final selected = state.selectedPlaylist;
      state = state.copyWith(
        playlists: await _store.listPlaylists(),
        selectedPlaylist: openPlaylist ? target : null,
        tracks: openPlaylist || selected?.id == target.id
            ? await _store.listTracks(target.id)
            : null,
        isLoading: false,
        clearError: true,
      );
      return (added: added, skipped: scan.skipped.length);
    } on Object catch (error) {
      state = state.copyWith(
        isLoading: false,
        error: AppFailure(
          code: AppFailureCode.unknown,
          message: '本地音频导入失败',
          diagnostic: error.runtimeType.toString(),
        ),
      );
      return null;
    }
  }

  Future<({UserPlaylist playlist, int added, int skipped})?> importDirectory(
    String path,
  ) async {
    if (state.isLoading) return null;
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final scan = await LocalAudioScanner().scanDirectory(path);
      if (scan.errorMessage case final message?) {
        state = state.copyWith(
          isLoading: false,
          error: AppFailure(code: AppFailureCode.invalidData, message: message),
        );
        return null;
      }
      final segments = Directory(path)
          .absolute
          .uri
          .pathSegments
          .where((segment) => segment.isNotEmpty)
          .toList();
      final playlist = await _store.createPlaylist(
        segments.isEmpty ? '本地音乐' : segments.last,
      );
      var added = 0;
      for (final track in scan.tracks) {
        if (await _store.addTrack(playlist.id, track)) added++;
      }
      state = state.copyWith(
        playlists: await _store.listPlaylists(),
        isLoading: false,
        clearError: true,
      );
      return (playlist: playlist, added: added, skipped: scan.skipped.length);
    } on Object catch (error) {
      state = state.copyWith(
        isLoading: false,
        error: AppFailure(
          code: AppFailureCode.unknown,
          message: '导入文件夹失败',
          diagnostic: error.runtimeType.toString(),
        ),
      );
      return null;
    }
  }

  Future<bool> isFavorite(String trackId) => _store.isFavorite(trackId);

  Future<bool> toggleFavorite(Track track) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final favorite = await _store.toggleFavorite(track);
      state = state.copyWith(
        tracks: state.selectedPlaylist?.id == LibraryStore.favoritesId
            ? await _store.listFavorites()
            : null,
        favoriteRevision: state.favoriteRevision + 1,
        isLoading: false,
        clearError: true,
      );
      return favorite;
    } on Object catch (error) {
      state = state.copyWith(
        isLoading: false,
        error: AppFailure(
          code: AppFailureCode.unknown,
          message: '收藏歌曲失败',
          diagnostic: error.runtimeType.toString(),
        ),
      );
      return false;
    }
  }

  Future<bool> isFavoriteOnlinePlaylist(OnlinePlaylist playlist) =>
      _store.isFavoriteOnlinePlaylist(playlist);

  Future<bool> toggleFavoriteOnlinePlaylist(PlaylistDetail detail) async {
    if (state.isLoading) return false;
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final favorite = await _store.toggleFavoriteOnlinePlaylist(detail);
      state = state.copyWith(
        favoriteOnlinePlaylists:
            state.selectedPlaylist?.id == LibraryStore.favoritesId
                ? await _store.listFavoriteOnlinePlaylists()
                : null,
        playlistFavoriteRevision: state.playlistFavoriteRevision + 1,
        isLoading: false,
        clearError: true,
      );
      return favorite;
    } on Object catch (error) {
      state = state.copyWith(
        isLoading: false,
        error: AppFailure(
          code: AppFailureCode.unknown,
          message: '收藏歌单失败',
          diagnostic: error.runtimeType.toString(),
        ),
      );
      return false;
    }
  }

  Future<bool> addFavoriteOnlinePlaylist(PlaylistDetail detail) async {
    if (state.isLoading) return false;
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final added = await _store.addFavoriteOnlinePlaylist(detail);
      state = state.copyWith(
        favoriteOnlinePlaylists:
            state.selectedPlaylist?.id == LibraryStore.favoritesId
                ? await _store.listFavoriteOnlinePlaylists()
                : null,
        playlistFavoriteRevision:
            state.playlistFavoriteRevision + (added ? 1 : 0),
        isLoading: false,
        clearError: true,
      );
      return added;
    } on Object catch (error) {
      state = state.copyWith(
        isLoading: false,
        error: AppFailure(
          code: AppFailureCode.unknown,
          message: '保存收藏歌单失败',
          diagnostic: error.runtimeType.toString(),
        ),
      );
      return false;
    }
  }

  Future<bool> toggleFavoriteAlbum(String name, List<Track> tracks) async {
    if (state.isLoading) return false;
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final favorite = await _store.toggleFavoriteAlbum(name, tracks);
      state = state.copyWith(
        favoriteAlbums: state.selectedPlaylist?.id == LibraryStore.favoritesId
            ? await _store.listFavoriteAlbums()
            : null,
        isLoading: false,
        clearError: true,
      );
      return favorite;
    } on Object catch (error) {
      state = state.copyWith(
        isLoading: false,
        error: AppFailure(
          code: AppFailureCode.unknown,
          message: '收藏专辑失败',
          diagnostic: error.runtimeType.toString(),
        ),
      );
      return false;
    }
  }

  Future<bool> isFavoriteAlbum(String name, List<Track> tracks) =>
      _store.isFavoriteAlbum(name, tracks);

  Future<void> removeTrack(String trackId) => _run(() async {
        final playlist = state.selectedPlaylist;
        if (playlist == null) return;
        await _store.removeTrack(playlist.id, trackId);
        state = state.copyWith(
          tracks: await _store.listTracks(playlist.id),
          isLoading: false,
          clearError: true,
        );
      });

  Future<void> removeTracks(Iterable<String> trackIds) => _run(() async {
        final playlist = state.selectedPlaylist;
        if (playlist == null) return;
        await _store.removeTracks(playlist.id, trackIds);
        state = state.copyWith(
          tracks: await _store.listTracks(playlist.id),
          isLoading: false,
          clearError: true,
        );
      });

  Future<void> reorderTracks(int oldIndex, int newIndex) {
    if (oldIndex < newIndex) newIndex--;
    if (oldIndex == newIndex) return Future.value();
    final tracks = [...state.tracks];
    final moved = tracks.removeAt(oldIndex);
    tracks.insert(newIndex, moved);
    return _run(() async {
      final playlist = state.selectedPlaylist;
      if (playlist == null) return;
      await _store.saveTrackOrder(
        playlist.id,
        tracks.map((track) => track.id).toList(growable: false),
      );
      state = state.copyWith(
        tracks: await _store.listTracks(playlist.id),
        isLoading: false,
        clearError: true,
      );
    });
  }

  Future<int> transferTracks(String targetPlaylistId, Iterable<String> ids,
      {required bool move}) async {
    if (state.isLoading) return 0;
    final playlist = state.selectedPlaylist;
    if (playlist == null) return 0;
    final selected = ids.toSet();
    final tracks = state.tracks
        .where((track) => selected.contains(track.id))
        .toList(growable: false);
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final added = await _store.transferTracks(
        fromPlaylistId: playlist.id,
        toPlaylistId: targetPlaylistId,
        tracks: tracks,
        move: move,
      );
      state = state.copyWith(
        tracks: move ? await _store.listTracks(playlist.id) : null,
        isLoading: false,
        clearError: true,
      );
      return added;
    } on Object catch (error) {
      state = state.copyWith(
        isLoading: false,
        error: AppFailure(
          code: AppFailureCode.unknown,
          message: move ? '移动歌曲失败' : '复制歌曲失败',
          diagnostic: error.runtimeType.toString(),
        ),
      );
      return 0;
    }
  }

  Future<void> pinTracks(Iterable<String> ids) {
    final playlist = state.selectedPlaylist;
    if (playlist == null) return Future.value();
    final selected = ids.toSet();
    final tracks = [
      ...state.tracks.where((track) => selected.contains(track.id)),
      ...state.tracks.where((track) => !selected.contains(track.id)),
    ];
    return _run(() async {
      await _store.saveTrackOrder(
        playlist.id,
        tracks.map((track) => track.id).toList(growable: false),
      );
      state = state.copyWith(
        tracks: await _store.listTracks(playlist.id),
        isLoading: false,
        clearError: true,
      );
    });
  }

  Future<void> reorder(int oldIndex, int newIndex) {
    if (oldIndex < newIndex) newIndex--;
    if (oldIndex == newIndex) return Future.value();
    final playlists = [...state.playlists];
    final moved = playlists.removeAt(oldIndex);
    playlists.insert(newIndex, moved);
    return _run(() async {
      await _store.saveOrder(playlists.map((playlist) => playlist.id).toList());
      state = state.copyWith(
        playlists: await _store.listPlaylists(),
        isLoading: false,
        clearError: true,
      );
    });
  }

  Future<void> _run(Future<void> Function() operation,
      {bool force = false}) async {
    if (state.isLoading && !force) return;
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      await operation();
    } on Object catch (error) {
      state = state.copyWith(
        isLoading: false,
        error: AppFailure(
          code: AppFailureCode.unknown,
          message: '列表数据保存失败',
          diagnostic: error.runtimeType.toString(),
        ),
      );
    }
  }
}
