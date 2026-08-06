import 'package:coral_music_mobile/domain/music.dart';
import 'package:coral_music_mobile/core/app_failure.dart';
import 'package:coral_music_mobile/features/song_list/data/kuwo_playlist_service.dart';
import 'package:coral_music_mobile/features/song_list/state/song_list_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('normalizePlaylistInput', () {
    test('reads playlist ids from the common shared-link query keys', () {
      expect(
        normalizePlaylistInput(
            'https://y.qq.com/n/ryqq/playlist/123?disstid=456'),
        '456',
      );
      expect(
        normalizePlaylistInput('https://music.163.com/playlist?id=789'),
        '789',
      );
      expect(
        normalizePlaylistInput(
            'https://www.kugou.com/yy/special/single/321.html'),
        '321',
      );
    });

    test('preserves a source-specific non-numeric identifier', () {
      expect(normalizePlaylistInput('kugou-code-abc'), 'kugou-code-abc');
      expect(normalizePlaylistInput('   '), isNull);
    });

    test('recognizes every supported platform from its official playlist URL',
        () {
      expect(
        parsePlaylistInput('https://music.163.com/#/playlist?id=2219770152'),
        isA<PlaylistInput>()
            .having((value) => value.source, 'source', OnlineSource.netease)
            .having((value) => value.id, 'id', '2219770152'),
      );
      expect(
        parsePlaylistInput('https://y.qq.com/n/ryqq_v2/playlist/2346298118'),
        isA<PlaylistInput>()
            .having((value) => value.source, 'source', OnlineSource.qq)
            .having((value) => value.id, 'id', '2346298118'),
      );
      expect(
        parsePlaylistInput('https://www.kuwo.cn/playlist_detail/3674194770'),
        isA<PlaylistInput>()
            .having((value) => value.source, 'source', OnlineSource.kuwo)
            .having((value) => value.id, 'id', '3674194770'),
      );
      expect(
        parsePlaylistInput(
            'https://www.kugou.com/songlist/gcid_3z9kil66z19z06e/'),
        isA<PlaylistInput>()
            .having((value) => value.source, 'source', OnlineSource.kugou)
            .having((value) => value.id, 'id', 'gcid_3z9kil66z19z06e'),
      );
      expect(
        parsePlaylistInput(
            'https://www.kugou.com/songlist/gcid_3zlgul1tzqrz02a/'),
        isA<PlaylistInput>()
            .having((value) => value.source, 'source', OnlineSource.kugou)
            .having((value) => value.id, 'id', 'gcid_3zlgul1tzqrz02a'),
      );
      expect(
        parsePlaylistInput(
          'https://music.migu.cn/v5/#/playlist?playlistId=231760782',
        ),
        isA<PlaylistInput>()
            .having((value) => value.source, 'source', OnlineSource.migu)
            .having((value) => value.id, 'id', '231760782'),
      );
    });
  });

  test('appends unique playlist pages and stops at the end', () async {
    final service = _FakePlaylistService();
    final controller = SongListController({OnlineSource.kuwo: service});
    addTearDown(controller.dispose);

    await controller.loadInitial();
    await controller.loadMore();
    await controller.loadMore();

    expect(service.requestedPages, [1, 2]);
    expect(controller.state.page, 2);
    expect(controller.state.hasNext, isFalse);
    expect(
      controller.state.playlists.map((item) => item.id),
      ['1', '2', '3'],
    );
  });

  test('does not replace an opened detail with the playlist square', () async {
    final service = _FakePlaylistService();
    final controller = SongListController({OnlineSource.kuwo: service});
    addTearDown(controller.dispose);

    await controller.open(_playlist1);
    await controller.loadInitial();

    expect(controller.state.detail?.playlist.id, '1');
    expect(service.requestedPages, isEmpty);
  });

  test('clears the previous detail when opening another playlist fails',
      () async {
    final controller = SongListController({
      OnlineSource.kuwo: _FakePlaylistService(),
      OnlineSource.kugou: _FailingPlaylistService(),
    });
    addTearDown(controller.dispose);

    await controller.open(_playlist1);
    await controller.open(const OnlinePlaylist(
      id: 'gcid_3zlgul1tzqrz02a',
      source: OnlineSource.kugou,
      name: '酷狗歌单',
    ));

    expect(controller.state.detail, isNull);
    expect(controller.state.error?.message, '酷狗歌单详情数据解析失败');
  });
}

final class _FakePlaylistService implements PlaylistCatalogService {
  final requestedPages = <int>[];

  @override
  Future<PageResult<OnlinePlaylist>> getPopularPlaylists(
    int page, {
    String? tagId,
    String sortId = 'hot',
  }) async {
    requestedPages.add(page);
    return PageResult(
      items: page == 1
          ? const [_playlist1, _playlist2]
          : const [_playlist2, _playlist3],
      page: page,
      pageSize: 2,
      total: 3,
    );
  }

  @override
  Future<List<PlaylistTag>> getTags() async => const [];

  @override
  Future<PlaylistDetail> getPlaylistDetail(OnlinePlaylist playlist) async =>
      PlaylistDetail(playlist: playlist, tracks: const []);

  @override
  Future<PageResult<OnlinePlaylist>> searchPlaylists(
    String query,
    int page,
  ) =>
      getPopularPlaylists(page);
}

final class _FailingPlaylistService implements PlaylistCatalogService {
  @override
  Future<List<PlaylistTag>> getTags() async => const [];

  @override
  Future<PageResult<OnlinePlaylist>> getPopularPlaylists(
    int page, {
    String? tagId,
    String sortId = 'hot',
  }) => throw UnimplementedError();

  @override
  Future<PlaylistDetail> getPlaylistDetail(OnlinePlaylist playlist) =>
      throw const AppFailure(
        code: AppFailureCode.invalidData,
        message: '酷狗歌单详情数据解析失败',
      );

  @override
  Future<PageResult<OnlinePlaylist>> searchPlaylists(String query, int page) =>
      throw UnimplementedError();
}

const _playlist1 = OnlinePlaylist(
  id: '1',
  source: OnlineSource.kuwo,
  name: '歌单 1',
);
const _playlist2 = OnlinePlaylist(
  id: '2',
  source: OnlineSource.kuwo,
  name: '歌单 2',
);
const _playlist3 = OnlinePlaylist(
  id: '3',
  source: OnlineSource.kuwo,
  name: '歌单 3',
);
