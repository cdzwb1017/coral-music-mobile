import 'package:coral_music_mobile/features/library/data/lx_sync_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses desktop list, love list, and user lists', () {
    final snapshot = LxSyncSnapshot.fromWire({
      'defaultList': [_track('default')],
      'loveList': [_track('love')],
      'userList': [
        {
          'name': '通勤',
          'list': [_track('commute')]
        },
      ],
    });

    expect(snapshot.defaultTracks.single.sourceTrackId, 'default');
    expect(snapshot.favoriteTracks.single.sourceTrackId, 'love');
    expect(snapshot.playlists.single.name, '通勤');
    expect(snapshot.playlists.single.tracks.single.sourceTrackId, 'commute');
  });

  const code = String.fromEnvironment('LX_SYNC_CONNECTION_CODE');
  test(
    'authenticates and reads a configured live service',
    () async {
      final snapshot = await LxSyncService().pull(
        host: 'https://gedan10.guoyue2010.top',
        connectionCode: code,
        persistCredential: false,
      );
      expect(snapshot.playlists, isA<List>());
    },
    skip: code.isEmpty ? 'requires LX_SYNC_CONNECTION_CODE' : false,
  );
}

Map<String, Object> _track(String id) => {
      'id': 'kg_$id',
      'source': 'kg',
      'name': '歌曲 $id',
      'singer': '歌手',
      'interval': '03:30',
      'meta': {'songId': id, 'albumName': '专辑'},
    };
