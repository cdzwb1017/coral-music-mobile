import 'package:audio_service/audio_service.dart';
import 'package:coral_music_mobile/features/player/data/audio_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('updates system media metadata when the player discovers duration', () {
    const item = MediaItem(id: 'local:1', title: '本地歌曲');

    final updated = mediaItemWithDuration(item, const Duration(minutes: 4));

    expect(updated.duration, const Duration(minutes: 4));
    expect(updated.title, item.title);
  });
}
