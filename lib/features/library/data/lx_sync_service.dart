import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/export.dart';

import '../../../domain/music.dart';
import 'playlist_transfer_codec.dart';

final class LxSyncSnapshot {
  const LxSyncSnapshot({
    required this.defaultTracks,
    required this.favoriteTracks,
    required this.playlists,
  });

  final List<Track> defaultTracks;
  final List<Track> favoriteTracks;
  final List<ImportedPlaylist> playlists;

  factory LxSyncSnapshot.fromWire(Object? raw) {
    final root = raw is Map ? raw : const <Object?, Object?>{};
    return LxSyncSnapshot(
      defaultTracks: _tracks(root['defaultList']),
      favoriteTracks: _tracks(root['loveList']),
      playlists: (root['userList'] as List? ?? const [])
          .whereType<Map>()
          .map((item) => ImportedPlaylist(
                name: '${item['name'] ?? item['id'] ?? ''}'.trim(),
                tracks: _tracks(item['list']),
              ))
          .where((playlist) => playlist.name.isNotEmpty)
          .toList(growable: false),
    );
  }

  static List<Track> _tracks(Object? raw) {
    final ids = <String>{};
    return (raw as List? ?? const [])
        .whereType<Map>()
        .map(PlaylistTransferCodec.decodeTrack)
        .whereType<Track>()
        .where((track) => ids.add(track.id))
        .toList(growable: false);
  }
}

final class LxSyncService {
  LxSyncService([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  Future<LxSyncSnapshot> pull({
    required String host,
    String? connectionCode,
    bool persistCredential = true,
  }) async {
    final endpoint = _endpoint(host);
    final hello = await _get(endpoint.resolve('hello'));
    if (hello != 'Hello~::^-^::~v4~') {
      throw const FormatException('不是兼容的落雪同步服务');
    }
    final serverId = await _get(endpoint.resolve('id'));
    if (!serverId.startsWith('OjppZDo6')) {
      throw const FormatException('无法识别落雪同步服务');
    }
    final storageKey =
        'lx-sync:${sha256.convert(utf8.encode(endpoint.origin))}';
    final saved = await _readCredential(storageKey);
    final code = connectionCode?.trim();
    final credential = code?.isNotEmpty == true
        ? await _authenticateByCode(endpoint, code!)
        : saved;
    if (credential == null) {
      throw const FormatException('首次同步需要填写连接码');
    }
    if (code?.isEmpty != false) await _authenticateByKey(endpoint, credential);
    if (code?.isNotEmpty == true && persistCredential) {
      await _storage.write(
          key: storageKey, value: jsonEncode(credential.toJson()));
    }
    return _readSnapshot(endpoint, credential);
  }

  Uri _endpoint(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      throw const FormatException('服务地址必须是 HTTP 或 HTTPS 地址');
    }
    return uri.replace(
        path: uri.path.endsWith('/') ? uri.path : '${uri.path}/');
  }

  Future<String> _get(Uri uri, {Map<String, String>? headers}) async {
    final client = HttpClient();
    try {
      final request =
          await client.getUrl(uri).timeout(const Duration(seconds: 12));
      headers?.forEach(request.headers.set);
      final response =
          await request.close().timeout(const Duration(seconds: 12));
      final text = await utf8.decoder.bind(response).join();
      if (response.statusCode != HttpStatus.ok) {
        throw FormatException('落雪服务认证失败（HTTP ${response.statusCode}）');
      }
      return text;
    } finally {
      client.close(force: true);
    }
  }

  Future<_LxCredential?> _readCredential(String storageKey) async {
    try {
      final raw = await _storage.read(key: storageKey);
      if (raw == null) return null;
      return _LxCredential.fromJson(jsonDecode(raw));
    } on Object {
      return null;
    }
  }

  Future<_LxCredential> _authenticateByCode(Uri endpoint, String code) async {
    final pair = _generateKeyPair();
    final key = base64Encode(utf8
        .encode(md5.convert(utf8.encode(code)).toString().substring(0, 16)));
    final publicKey = _publicKeyBase64(pair.publicKey);
    final response = await _get(
      endpoint.resolve('ah'),
      headers: {
        'm': _aesEncrypt(
            'lx-music auth::\n$publicKey\nCoral Music\nlx_music_mobile', key),
      },
    );
    try {
      final plain =
          _standardOaepDecrypt(base64Decode(response), pair.privateKey);
      return _LxCredential.fromJson(jsonDecode(utf8.decode(plain)));
    } on Object {
      throw const FormatException('连接码认证失败');
    }
  }

  Future<void> _authenticateByKey(
      Uri endpoint, _LxCredential credential) async {
    final response = await _get(
      endpoint.resolve('ah'),
      headers: {
        'i': credential.clientId,
        'm': _aesEncrypt('lx-music auth::Coral Music', credential.key),
      },
    );
    if (_aesDecrypt(response, credential.key) != 'Hello~::^-^::~v4~') {
      throw const FormatException('保存的落雪凭据已失效，请重新填写连接码');
    }
  }

  Future<LxSyncSnapshot> _readSnapshot(
      Uri endpoint, _LxCredential credential) async {
    final scheme = endpoint.scheme == 'https' ? 'wss' : 'ws';
    final socket = await WebSocket.connect(
      endpoint.replace(
        scheme: scheme,
        path: '${endpoint.path}socket',
        queryParameters: {
          'i': credential.clientId,
          't': _aesEncrypt('lx-music connect', credential.key),
        },
      ).toString(),
    ).timeout(const Duration(seconds: 15));
    final completed = Completer<LxSyncSnapshot>();
    Object? snapshot;
    late final StreamSubscription subscription;
    subscription = socket.listen((raw) {
      if (raw == 'ping') return;
      try {
        var text = raw is String ? raw : utf8.decode(raw as List<int>);
        if (text.startsWith('cg_')) {
          text = utf8.decode(gzip.decode(base64Decode(text.substring(3))));
        }
        final message = jsonDecode(text);
        if (message is! Map ||
            message['path'] is! List ||
            message['name'] is! String) {
          return;
        }
        final path =
            (message['path'] as List).map((value) => '$value').join('.');
        Object? data;
        if (path == 'getEnabledFeatures') {
          data = {
            'list': {'skipSnapshot': true}
          };
        } else if (path == 'list_sync_get_list_data') {
          data = {'defaultList': [], 'loveList': [], 'userList': []};
        } else if (path == 'list_sync_set_list_data') {
          snapshot = (message['data'] as List?)?.first;
        } else if (path == 'finished') {
          data = null;
          if (!completed.isCompleted) {
            completed.complete(LxSyncSnapshot.fromWire(snapshot));
          }
        }
        socket.add(
            jsonEncode({'name': message['name'], 'error': null, 'data': data}));
      } on Object catch (error) {
        if (!completed.isCompleted) completed.completeError(error);
      }
    }, onError: (Object error) {
      if (!completed.isCompleted) completed.completeError(error);
    }, onDone: () {
      if (!completed.isCompleted) {
        completed.completeError(const FormatException('落雪同步连接已断开'));
      }
    });
    try {
      return await completed.future.timeout(const Duration(seconds: 45));
    } finally {
      await subscription.cancel();
      await socket.close();
    }
  }

  AsymmetricKeyPair<RSAPublicKey, RSAPrivateKey> _generateKeyPair() {
    final seed = Uint8List.fromList(
        List<int>.generate(32, (_) => Random.secure().nextInt(256)));
    final random = FortunaRandom()..seed(KeyParameter(seed));
    final generator = RSAKeyGenerator()
      ..init(ParametersWithRandom(
          RSAKeyGeneratorParameters(BigInt.from(65537), 2048, 64), random));
    final pair = generator.generateKeyPair();
    return AsymmetricKeyPair(
        pair.publicKey as RSAPublicKey, pair.privateKey as RSAPrivateKey);
  }

  String _publicKeyBase64(RSAPublicKey key) {
    final algorithm = ASN1Sequence()
      ..add(ASN1ObjectIdentifier.fromIdentifierString('1.2.840.113549.1.1.1'))
      ..add(ASN1Null());
    final rsa = ASN1Sequence()
      ..add(ASN1Integer(key.modulus))
      ..add(ASN1Integer(key.exponent));
    final spki = ASN1Sequence()
      ..add(algorithm)
      ..add(ASN1BitString(stringValues: rsa.encode()));
    return base64Encode(spki.encode());
  }

  Uint8List _standardOaepDecrypt(List<int> encrypted, RSAPrivateKey key) {
    final engine = RSAEngine()
      ..init(false, PrivateKeyParameter<RSAPrivateKey>(key));
    final raw = engine.process(Uint8List.fromList(encrypted));
    final encoded = Uint8List(encrypted.length)
      ..setRange(encrypted.length - raw.length, encrypted.length, raw);
    const hashLength = 20;
    if (encoded.length < 2 * hashLength + 2 || encoded.first != 0) {
      throw const FormatException('无效的落雪认证回包');
    }
    final maskedSeed = encoded.sublist(1, hashLength + 1);
    final maskedData = encoded.sublist(hashLength + 1);
    final seed = _xor(maskedSeed, _mgf1(maskedData, hashLength));
    final data = _xor(maskedData, _mgf1(seed, maskedData.length));
    final labelHash = sha1.convert(const []).bytes;
    if (!_sameBytes(data.sublist(0, hashLength), labelHash)) {
      throw const FormatException('无效的落雪认证回包');
    }
    var index = hashLength;
    while (index < data.length && data[index] == 0) {
      index++;
    }
    if (index == data.length || data[index] != 1) {
      throw const FormatException('无效的落雪认证回包');
    }
    return Uint8List.fromList(data.sublist(index + 1));
  }

  Uint8List _mgf1(List<int> seed, int length) {
    final output = <int>[];
    for (var counter = 0; output.length < length; counter++) {
      output.addAll(sha1.convert([
        ...seed,
        (counter >> 24) & 0xff,
        (counter >> 16) & 0xff,
        (counter >> 8) & 0xff,
        counter & 0xff,
      ]).bytes);
    }
    return Uint8List.fromList(output.take(length).toList(growable: false));
  }

  Uint8List _xor(List<int> left, List<int> right) => Uint8List.fromList(
        List<int>.generate(left.length, (index) => left[index] ^ right[index]),
      );

  bool _sameBytes(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }

  String _aesEncrypt(String text, String key) =>
      base64Encode(_aes(utf8.encode(text), base64Decode(key), true));

  String _aesDecrypt(String text, String key) =>
      utf8.decode(_aes(base64Decode(text), base64Decode(key), false));

  Uint8List _aes(List<int> input, List<int> key, bool encrypt) {
    final cipher =
        PaddedBlockCipherImpl(PKCS7Padding(), ECBBlockCipher(AESEngine()))
          ..init(
              encrypt,
              PaddedBlockCipherParameters<KeyParameter, Null>(
                  KeyParameter(Uint8List.fromList(key)), null));
    return cipher.process(Uint8List.fromList(input));
  }
}

final class _LxCredential {
  const _LxCredential(
      {required this.clientId, required this.key, required this.serverName});

  final String clientId;
  final String key;
  final String serverName;

  factory _LxCredential.fromJson(Object? raw) {
    if (raw is! Map) throw const FormatException('落雪认证数据无效');
    final clientId = '${raw['clientId'] ?? ''}';
    final key = '${raw['key'] ?? ''}';
    final serverName = '${raw['serverName'] ?? ''}';
    if (clientId.isEmpty || key.isEmpty) {
      throw const FormatException('落雪认证数据无效');
    }
    return _LxCredential(clientId: clientId, key: key, serverName: serverName);
  }

  Map<String, String> toJson() =>
      {'clientId': clientId, 'key': key, 'serverName': serverName};
}
