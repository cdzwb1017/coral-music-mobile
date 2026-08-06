import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import '../../../core/app_failure.dart';
import '../../../core/http_client.dart';
import '../../../core/response_json.dart';
import '../../../domain/music.dart';
import 'kuwo_playlist_service.dart';

final class KugouPlaylistService implements PlaylistCatalogService {
  KugouPlaylistService(this._dio);

  final Dio _dio;
  @override
  Future<List<PlaylistTag>> getTags() async => const [];

  @override
  Future<PageResult<OnlinePlaylist>> getPopularPlaylists(
    int page, {
    String? tagId,
    String sortId = 'hot',
  }) async {
    if (page < 1) {
      throw const AppFailure(
          code: AppFailureCode.invalidData, message: '酷狗歌单页码无效');
    }
    try {
      final response = await _dio.getUri<Object?>(
        Uri.https('m.kugou.com', '/plist/index', {
          'json': 'true',
          'page': '$page',
        }),
      );
      return parseKugouPopularPlaylists(response.data, page: page);
    } on DioException catch (error) {
      throw mapDioException(error);
    } on AppFailure {
      rethrow;
    } on Object catch (error) {
      throw AppFailure(
        code: AppFailureCode.invalidData,
        message: '酷狗歌单广场数据解析失败',
        diagnostic: error.runtimeType.toString(),
      );
    }
  }

  @override
  Future<PageResult<OnlinePlaylist>> searchPlaylists(
    String query,
    int page,
  ) async {
    final keyword = query.trim();
    if (keyword.isEmpty || page < 1) {
      throw const AppFailure(
          code: AppFailureCode.invalidData, message: '酷狗歌单搜索参数无效');
    }
    try {
      final response = await _dio.getUri<Object?>(
        Uri.https('msearchretry.kugou.com', '/api/v3/search/special', {
          'keyword': keyword,
          'page': '$page',
          'pagesize': '30',
          'showtype': '10',
          'filter': '0',
          'version': '7910',
          'sver': '2',
        }),
      );
      return parseKugouSearchPlaylists(response.data, page: page);
    } on DioException catch (error) {
      throw mapDioException(error);
    } on AppFailure {
      rethrow;
    } on Object catch (error) {
      throw AppFailure(
        code: AppFailureCode.invalidData,
        message: '酷狗歌单搜索数据解析失败',
        diagnostic: error.runtimeType.toString(),
      );
    }
  }

  @override
  Future<PlaylistDetail> getPlaylistDetail(OnlinePlaylist playlist) async {
    if (playlist.source != OnlineSource.kugou || playlist.id.trim().isEmpty) {
      throw const AppFailure(
          code: AppFailureCode.invalidData, message: '酷狗歌单标识无效');
    }
    try {
      if (playlist.id.startsWith('gcid_')) {
        return await _getGcidPlaylistDetail(playlist);
      }
      final results = await Future.wait([
        _dio.getUri<Object?>(
          Uri.http('mobilecdn.kugou.com', '/api/v3/special/info', {
            'specialid': playlist.id,
          }),
        ),
        _dio.getUri<Object?>(
          Uri.http('mobilecdn.kugou.com', '/api/v3/special/song', {
            'specialid': playlist.id,
            'page': '1',
            'pagesize': '200',
          }),
        ),
      ]);
      return parseKugouPlaylistDetailV3(
        results[0].data,
        results[1].data,
        playlist,
      );
    } on DioException catch (error) {
      throw mapDioException(error);
    } on AppFailure {
      rethrow;
    } on Object catch (error) {
      throw AppFailure(
        code: AppFailureCode.invalidData,
        message: '酷狗歌单详情数据解析失败',
        diagnostic: error.runtimeType.toString(),
      );
    }
  }

  Future<PlaylistDetail> _getGcidPlaylistDetail(OnlinePlaylist playlist) async {
    final clientTime = DateTime.now().millisecondsSinceEpoch.toString();
    final decodeParams =
        'dfid=-&appid=1005&srcappid=2919&mid=$clientTime&clientver=20000&clienttime=$clientTime&uuid=$clientTime';
    final decodeBody = {
      'ret_info': 1,
      'data': [
        {'id': playlist.id.substring(5), 'id_type': 2},
      ],
    };
    final decoded = await _dio.postUri<Object?>(
      Uri.https('t.kugou.com', '/v1/songlist/batch_decode', {
        ..._query(decodeParams),
        'signature': _signature(decodeParams, body: jsonEncode(decodeBody)),
      }),
      data: decodeBody,
      options: Options(headers: const {
        'User-Agent':
            'Mozilla/5.0 (Linux; Android 10) AppleWebKit/537.36 Chrome/83.0.4103.106 Mobile Safari/537.36',
        'Referer': 'https://m.kugou.com/',
      }),
    );
    final decodedRoot = decodeJsonMap(decoded.data);
    final decodedData =
        decodedRoot['data'] is Map ? decodedRoot['data'] as Map : decodedRoot;
    final decodedList = decodedData['list'];
    final decodedItem = decodedList is List
        ? decodedList.whereType<Map>().firstOrNull
        : null;
    final globalId = decodedItem == null
        ? ''
        : '${decodedItem['global_collection_id'] ?? ''}'.trim();
    if (globalId.isEmpty) {
      throw const AppFailure(
        code: AppFailureCode.invalidData,
        message: '酷狗歌单分享链接解析失败',
      );
    }
    final decodedInfo = decodedItem?['info'];
    final specialId = decodedInfo is Map
        ? '${decodedInfo['specialid'] ?? ''}'.trim()
        : '';
    if (specialId.isNotEmpty) {
      final results = await Future.wait([
        _dio.getUri<Object?>(
          Uri.http('mobilecdn.kugou.com', '/api/v3/special/info', {
            'specialid': specialId,
          }),
        ),
        _dio.getUri<Object?>(
          Uri.http('mobilecdn.kugou.com', '/api/v3/special/song', {
            'specialid': specialId,
            'page': '1',
            'pagesize': '300',
          }),
        ),
      ]);
      return parseKugouPlaylistDetailV3(
        results[0].data,
        results[1].data,
        playlist,
      );
    }
    const infoParams =
        'appid=1058&specialid=0&format=jsonp&srcappid=2919&clientver=20000&clienttime=1586163242519&mid=1586163242519&uuid=1586163242519&dfid=-';
    final info = await _dio.getUri<Object?>(
      Uri.https('mobiles.kugou.com', '/api/v5/special/info_v2', {
        ..._query('$infoParams&global_specialid=$globalId'),
        'signature': _signature('$infoParams&global_specialid=$globalId'),
      }),
      options: _kugouWebOptions(
        mid: '1586163242519',
        clienttime: '1586163242519',
      ),
    );
    const songParamsPrefix =
        'appid=1058&specialid=0&plat=0&version=8000&srcappid=2919&clientver=20000&clienttime=1586163263991&mid=1586163263991&uuid=1586163263991&dfid=-';
    final songParams =
        '$songParamsPrefix&global_specialid=$globalId&page=1&pagesize=300';
    final songs = await _dio.getUri<Object?>(
      Uri.https('mobiles.kugou.com', '/api/v5/special/song_v2', {
        ..._query(songParams),
        'signature': _signature(songParams),
      }),
      options: _kugouWebOptions(
        mid: '1586163263991',
        clienttime: '1586163263991',
      ),
    );
    return parseKugouPlaylistDetailV3(info.data, songs.data, playlist);
  }

  static Options _kugouWebOptions({
    required String mid,
    required String clienttime,
  }) =>
      Options(headers: {
        'mid': mid,
        'Referer': 'https://m3ws.kugou.com/share/index.php',
        'User-Agent':
            'Mozilla/5.0 (iPhone; CPU iPhone OS 11_0 like Mac OS X) AppleWebKit/604.1.38 Mobile/15E148 Safari/604.1',
        'dfid': '-',
        'clienttime': clienttime,
      });

  static Map<String, String> _query(String value) => {
        for (final item in value.split('&'))
          if (item.contains('='))
            item.substring(0, item.indexOf('=')):
                item.substring(item.indexOf('=') + 1),
      };

  static String _signature(String params, {String body = ''}) {
    const key = 'NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt';
    final sorted = params.split('&')..sort();
    return md5.convert(utf8.encode('$key${sorted.join()}$body$key')).toString();
  }
}

PageResult<OnlinePlaylist> parseKugouPopularPlaylists(
  Object? raw, {
  required int page,
}) {
  final playlist = decodeJsonMap(raw)['plist'] as Map?;
  final data = playlist?['list'] as Map?;
  final items = data?['info'];
  if (items is! List) {
    throw const AppFailure(
        code: AppFailureCode.invalidData, message: '酷狗歌单广场响应异常');
  }
  final playlists = items
      .whereType<Map>()
      .map(_playlist)
      .whereType<OnlinePlaylist>()
      .toList(growable: false);
  return PageResult(
    items: playlists,
    page: page,
    pageSize: 30,
    total: int.tryParse('${data?['total'] ?? ''}') ?? playlists.length,
  );
}

PageResult<OnlinePlaylist> parseKugouSearchPlaylists(
  Object? raw, {
  required int page,
}) {
  final response = decodeJsonMap(raw);
  final data = response['data'] as Map?;
  final items = data?['info'];
  if ('${response['errcode'] ?? ''}' != '0' || items is! List) {
    throw const AppFailure(
        code: AppFailureCode.invalidData, message: '酷狗歌单搜索响应异常');
  }
  final playlists = items
      .whereType<Map>()
      .map(_playlist)
      .whereType<OnlinePlaylist>()
      .toList(growable: false);
  return PageResult(
    items: playlists,
    page: page,
    pageSize: 30,
    total: int.tryParse('${data?['total'] ?? ''}') ?? playlists.length,
  );
}

PlaylistDetail parseKugouPlaylistDetailV3(
  Object? infoRaw,
  Object? songsRaw,
  OnlinePlaylist fallback,
) {
  final infoData = (decodeJsonMap(infoRaw)['data'] as Map?);
  final songData = (decodeJsonMap(songsRaw)['data'] as Map?);
  final rawTracks = songData?['info'];
  if (rawTracks is! List) {
    throw const AppFailure(
        code: AppFailureCode.invalidData, message: '酷狗歌单歌曲缺失');
  }
  final tracks = rawTracks
      .whereType<Map>()
      .map(_track)
      .whereType<Track>()
      .toList(growable: false);
  if (tracks.isEmpty) {
    throw const AppFailure(
        code: AppFailureCode.invalidData, message: '酷狗歌单歌曲缺失');
  }
  return PlaylistDetail(
    playlist: OnlinePlaylist(
      id: fallback.id,
      source: OnlineSource.kugou,
      name: '${infoData?['specialname'] ?? fallback.name}'.trim(),
      author: '${infoData?['nickname'] ?? fallback.author}'.trim(),
      description: '${infoData?['intro'] ?? fallback.description}'.trim(),
      trackCount: tracks.length,
      coverUri: _uri(infoData?['imgurl']) ??
          fallback.coverUri ??
          tracks.first.coverUri,
    ),
    tracks: tracks,
  );
}

OnlinePlaylist? _playlist(Map item) {
  final id = '${item['specialid'] ?? ''}'.trim();
  final name = '${item['specialname'] ?? ''}'.trim();
  if (id.isEmpty || name.isEmpty) return null;
  return OnlinePlaylist(
    id: id,
    source: OnlineSource.kugou,
    name: name,
    author: '${item['nickname'] ?? ''}'.trim(),
    description: '${item['intro'] ?? ''}'.trim(),
    trackCount: int.tryParse('${item['songcount'] ?? ''}') ?? 0,
    playCount: _formatCount(item['playcount']),
    coverUri: _uri(item['imgurl']),
  );
}

Track? _track(Map item) {
  final hash = '${item['hash'] ?? item['HASH'] ?? ''}'.trim();
  final filename =
      '${item['filename'] ?? item['songname'] ?? item['audio_name'] ?? ''}'
          .trim();
  if (hash.isEmpty || filename.isEmpty) return null;
  var title = filename;
  var artist = '${item['author_name'] ?? item['singername'] ?? ''}'.trim();
  if (artist.isEmpty) {
    final dashIndex = filename.indexOf(' - ');
    if (dashIndex > 0) {
      artist = filename.substring(0, dashIndex).trim();
      title = filename.substring(dashIndex + 3).trim();
    }
  }
  final meta = <String, Map<String, Object?>>{};
  void add(String name, String hashKey, String sizeKey) {
    final qualityHash = '${item[hashKey] ?? ''}'.trim();
    final size = int.tryParse('${item[sizeKey] ?? ''}') ?? 0;
    if (qualityHash.isNotEmpty && size > 0) {
      meta[name] = {'hash': qualityHash, 'size': size};
    }
  }

  add('128k', 'hash', 'filesize');
  add('320k', '320hash', '320filesize');
  add('flac', 'sqhash', 'sqfilesize');
  final trans = item['trans_param'];
  return Track(
    sourceKind: TrackSourceKind.online,
    sourceId: OnlineSource.kugou.id,
    sourceTrackId: hash,
    title: title,
    artist: artist,
    album: '${item['album_name'] ?? ''}'.trim(),
    duration: _duration(item['duration'] ?? item['timelength']),
    coverUri: _uri(trans is Map ? trans['union_cover'] : null),
    availableQualities: [
      if (meta.containsKey('flac')) AudioQuality.flac,
      if (meta.containsKey('320k')) AudioQuality.high320k,
      if (meta.containsKey('128k')) AudioQuality.standard128k,
    ],
    extra: {
      'albumId': item['album_id'],
      'hash': hash,
      'qualityMeta': meta,
    },
  );
}

Duration? _duration(Object? value) {
  final milliseconds = int.tryParse('$value');
  if (milliseconds == null || milliseconds <= 0) return null;
  return Duration(
      milliseconds: milliseconds < 1000 ? milliseconds * 1000 : milliseconds);
}

Uri? _uri(Object? value) {
  final raw = '$value'.trim().replaceAll('{size}', '480');
  final uri = Uri.tryParse(raw);
  if (uri == null || uri.host.isEmpty) return null;
  return uri.scheme == 'http' ? uri.replace(scheme: 'https') : uri;
}

String _formatCount(Object? value) {
  final count = int.tryParse('$value') ?? 0;
  if (count >= 100000000) return '${(count / 10000000).toStringAsFixed(1)}亿';
  if (count >= 10000) return '${(count / 10000).toStringAsFixed(1)}万';
  return count == 0 ? '' : '$count';
}
