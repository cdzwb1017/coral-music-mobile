import 'package:coral_music_mobile/domain/music.dart';
import 'package:coral_music_mobile/features/leaderboard/data/online_catalog_service.dart';
import 'package:coral_music_mobile/features/player/data/track_artwork_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('searches a catalog for missing WebDAV and local artwork', () async {
    final resolver = TrackArtworkResolver({
      OnlineSource.kuwo: _Catalog(),
    });

    for (final source in [TrackSourceKind.webdav, TrackSourceKind.local]) {
      final cover = await resolver.resolve(Track(
        sourceKind: source,
        sourceId: source.name,
        sourceTrackId: 'song.flac',
        title: '网盘歌曲',
        artist: '',
      ));

      expect(cover, Uri.parse('https://cover.example.com/song.jpg'));
    }
  });
}

final class _Catalog implements OnlineCatalogService {
  @override
  Future<List<LeaderboardBoard>> getLeaderboardBoards(
          OnlineSource source) async =>
      const [];

  @override
  Future<PageResult<Track>> getLeaderboardDetail(
          OnlineSource source, String boardId, int page) async =>
      const PageResult(items: [], page: 1, pageSize: 1, total: 0);

  @override
  Future<PageResult<Track>> searchTracks(
          OnlineSource source, String query, int page) async =>
      PageResult(
        items: [
          Track(
            sourceKind: TrackSourceKind.online,
            sourceId: 'kw',
            sourceTrackId: '1',
            title: '网盘歌曲',
            artist: '',
            coverUri: Uri.parse('https://cover.example.com/song.jpg'),
          ),
        ],
        page: 1,
        pageSize: 1,
        total: 1,
      );
}
