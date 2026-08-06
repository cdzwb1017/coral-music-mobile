import 'dart:math';

class SeasonalPhrase {
  const SeasonalPhrase(this.text, this.category);

  final String text;
  final String category;
}

const _seasonPhrases = <List<String>>[
  ['青阳启序', '芳郊叠翠', '淑气初回'],
  ['朱明长昼', '槐荫匝地', '炎序流金'],
  ['白藏敛霜', '素商桂月', '金行肃远'],
  ['玄英闭藏', '北陆凝寒', '严节梅破'],
];

const _monthPhrases = <String>[
  '端月柳醒',
  '杏月桃夭',
  '桃月桐华',
  '梅月麦秋',
  '榴月蒲绿',
  '荷月莲沸',
  '兰月鹊渡',
  '桂月秔香',
  '菊月萸紫',
  '阳月芦白',
  '葭月雪初',
  '腊月岁暮',
];

const _solarTerms = <({int month, int day, String name, String phrase})>[
  (month: 1, day: 6, name: '小寒', phrase: '雁北初乡'),
  (month: 1, day: 20, name: '大寒', phrase: '凛极回春'),
  (month: 2, day: 4, name: '立春', phrase: '东风解冻'),
  (month: 2, day: 19, name: '雨水', phrase: '甘霖润陌'),
  (month: 3, day: 5, name: '惊蛰', phrase: '启蛰闻雷'),
  (month: 3, day: 21, name: '春分', phrase: '昼夜中分'),
  (month: 4, day: 5, name: '清明', phrase: '柳烟啼莺'),
  (month: 4, day: 20, name: '谷雨', phrase: '萍生麦秀'),
  (month: 5, day: 6, name: '立夏', phrase: '槐序初开'),
  (month: 5, day: 21, name: '小满', phrase: '麦气微盈'),
  (month: 6, day: 6, name: '芒种', phrase: '刈绿播黄'),
  (month: 6, day: 21, name: '夏至', phrase: '日永影短'),
  (month: 7, day: 7, name: '小暑', phrase: '温风始至'),
  (month: 7, day: 23, name: '大暑', phrase: '焚景流金'),
  (month: 8, day: 8, name: '立秋', phrase: '金气始肃'),
  (month: 8, day: 23, name: '处暑', phrase: '暑退凉生'),
  (month: 9, day: 8, name: '白露', phrase: '玉露凝阶'),
  (month: 9, day: 23, name: '秋分', phrase: '衡影均长'),
  (month: 10, day: 8, name: '寒露', phrase: '珠结幽丛'),
  (month: 10, day: 23, name: '霜降', phrase: '初霜陨草'),
  (month: 11, day: 7, name: '立冬', phrase: '水始成冰'),
  (month: 11, day: 22, name: '小雪', phrase: '絮落无声'),
  (month: 12, day: 7, name: '大雪', phrase: '山色尽封'),
  (month: 12, day: 22, name: '冬至', phrase: '日短归阳'),
];

List<SeasonalPhrase> seasonalPhraseCandidates(DateTime date) {
  final season = switch (date.month) {
    3 || 4 || 5 => 0,
    6 || 7 || 8 => 1,
    9 || 10 || 11 => 2,
    _ => 3,
  };
  final term = _solarTermFor(date);
  return [
    ..._seasonPhrases[season].map((text) => SeasonalPhrase(text, '季节')),
    SeasonalPhrase(_monthPhrases[date.month - 1], '月份'),
    SeasonalPhrase(term.phrase, term.name),
  ];
}

SeasonalPhrase randomSeasonalPhrase(DateTime date, {Random? random}) {
  final source = random ?? Random();
  final season = switch (date.month) {
    3 || 4 || 5 => 0,
    6 || 7 || 8 => 1,
    9 || 10 || 11 => 2,
    _ => 3,
  };
  final term = _solarTermFor(date);
  // ponytail: one random choice per page instance keeps the banner stable while data loads.
  return switch (source.nextInt(3)) {
    0 => SeasonalPhrase(_seasonPhrases[season][source.nextInt(3)], '季节'),
    1 => SeasonalPhrase(_monthPhrases[date.month - 1], '月份'),
    _ => SeasonalPhrase(term.phrase, term.name),
  };
}

({String name, String phrase}) _solarTermFor(DateTime date) {
  final year = date.year;
  final current = DateTime(year, date.month, date.day);
  var result = (name: '冬至', phrase: '日短归阳');
  for (final term in _solarTerms) {
    final start = DateTime(year, term.month, term.day);
    if (!start.isAfter(current)) {
      result = (name: term.name, phrase: term.phrase);
    }
  }
  if (current.isBefore(DateTime(year, 1, 6))) {
    result = (name: '冬至', phrase: '日短归阳');
  }
  return result;
}
