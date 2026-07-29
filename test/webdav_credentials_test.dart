import 'package:coral_music_mobile/domain/music.dart';
import 'package:coral_music_mobile/features/webdav/data/webdav_credentials.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('WebDAV account index never serializes authorization', () {
    final encoded = WebDavCredentials.encodeAccounts([
      WebDavAccount(
        id: 'https://dav.example.com/music/',
        name: '家庭音乐库',
        endpoint: Uri.parse('https://dav.example.com/music/'),
        protocol: WebDavProtocol.openlist,
      ),
    ]);

    final accounts = WebDavCredentials.decodeAccounts(encoded);

    expect(accounts.single.name, '家庭音乐库');
    expect(accounts.single.endpoint.host, 'dav.example.com');
    expect(accounts.single.protocol, WebDavProtocol.openlist);
    expect(encoded, isNot(contains('Authorization')));
  });

  test('old WebDAV accounts remain standard WebDAV connections', () {
    final accounts = WebDavCredentials.decodeAccounts(
      '[{"id":"dav","name":"旧连接","endpoint":"https://dav.example.com/"}]',
    );

    expect(accounts.single.protocol, WebDavProtocol.webdav);
  });

  test('migrates the earlier OpenList dav suffix to the dav root', () {
    final accounts = WebDavCredentials.decodeAccounts('''
[{"id":"openlist","name":"OpenList","endpoint":"http://host/music/dav/","protocol":"openlist"}]''');

    expect(accounts.single.endpoint, Uri.parse('http://host/dav/music/'));
  });
}
