import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:coral_music_mobile/features/leaderboard/data/seasonal_phrase.dart';

void main() {
  test('candidates match the date season, month and solar term', () {
    final candidates = seasonalPhraseCandidates(DateTime(2026, 8, 6));
    final texts = candidates.map((candidate) => candidate.text).toSet();

    expect(texts, contains('朱明长昼'));
    expect(texts, contains('桂月秔香'));
    expect(texts, contains('焚景流金'));
  });

  test('selection returns one of the date-matched candidates', () {
    final candidates = seasonalPhraseCandidates(DateTime(2026, 12, 25));
    final selected =
        randomSeasonalPhrase(DateTime(2026, 12, 25), random: Random(1));

    expect(
        candidates.map((candidate) => candidate.text), contains(selected.text));
  });
}
