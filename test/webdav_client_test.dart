import 'dart:io';

import 'package:dio/dio.dart';
import 'package:coral_music_mobile/domain/music.dart';
import 'package:coral_music_mobile/features/webdav/data/webdav_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('keeps WebDAV parent navigation inside the configured root', () {
    final root = Uri.parse('https://dav.example.com/music/');

    expect(
      parentWebDavDirectory(
        Uri.parse('https://dav.example.com/music/album/disc/'),
        root,
      ),
      Uri.parse('https://dav.example.com/music/album/'),
    );
    expect(parentWebDavDirectory(root, root), isNull);
    expect(
      parentWebDavDirectory(Uri.parse('https://dav.example.com/other/'), root),
      isNull,
    );
  });

  test('builds breadcrumbs only inside the configured root', () {
    final root = Uri.parse('https://dav.example.com/music/');
    final breadcrumbs = webDavBreadcrumbs(
      Uri.parse('https://dav.example.com/music/album/disc-1/'),
      root,
    );

    expect(
      breadcrumbs.map((item) => item.path),
      ['/music/', '/music/album/', '/music/album/disc-1/'],
    );
    expect(
      webDavBreadcrumbs(Uri.parse('https://dav.example.com/other/'), root),
      [root],
    );
  });

  test('normalizes AList and OpenList endpoints and builds Basic auth', () {
    expect(
      normalizeWebDavEndpoint(
        Uri.parse('https://alist.example.com/base'),
        WebDavProtocol.alist,
      ),
      Uri.parse('https://alist.example.com/dav/base/'),
    );
    expect(
      normalizeWebDavEndpoint(
        Uri.parse('https://openlist.example.com/dav/music'),
        WebDavProtocol.openlist,
      ),
      Uri.parse('https://openlist.example.com/dav/music/'),
    );
    expect(
      normalizeWebDavEndpoint(
        Uri.parse('http://192.168.107.237:5244/hi-res/hi-res'),
        WebDavProtocol.openlist,
      ),
      Uri.parse('http://192.168.107.237:5244/dav/hi-res/hi-res/'),
    );
    expect(
      normalizeWebDavEndpoint(
        Uri.parse('http://192.168.107.237:5244/hi-res/hi-res/dav/'),
        WebDavProtocol.openlist,
      ),
      Uri.parse('http://192.168.107.237:5244/dav/hi-res/hi-res/'),
    );

    final authorization = webDavBasicAuthorization('珊瑚', 'p:a:ss');
    expect(
      parseWebDavBasicAuthorization(authorization),
      (username: '珊瑚', password: 'p:a:ss'),
    );
  });

  test('keeps encoded WebDAV href characters in the playback URL', () {
    final track = WebDavClient(Dio()).toTrack(
      const WebDavEntry(
          path: '/dav/music/track%3Ftake.mp3', isDirectory: false),
      accountId: 'openlist',
      endpoint: Uri.parse('https://openlist.example.com/dav/'),
    );

    expect(
      track.localUri,
      Uri.parse('https://openlist.example.com/dav/music/track%3Ftake.mp3'),
    );
  });

  test('accepts successful PROPFIND responses that use HTTP 200', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((request) async {
      expect(request.method, 'PROPFIND');
      request.response.statusCode = HttpStatus.ok;
      request.response.write('''
<D:multistatus xmlns:D="DAV:">
  <D:response><D:href>/dav/song.mp3</D:href></D:response>
</D:multistatus>''');
      await request.response.close();
    });

    final entries = await WebDavClient(Dio()).list(
      Uri.parse('http://${server.address.address}:${server.port}/dav/'),
      authorization: 'Basic test',
    );

    expect(entries.single.path, '/dav/song.mp3');
  });

  test('recognizes OpenList collection tags with XML attributes', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((request) async {
      request.response.statusCode = HttpStatus.multiStatus;
      request.response.write('''
<D:multistatus xmlns:D="DAV:">
  <D:response><D:href>/dav/album/</D:href><D:resourcetype><D:collection xmlns:D="DAV:"/></D:resourcetype></D:response>
</D:multistatus>''');
      await request.response.close();
    });

    final entries = await WebDavClient(Dio()).list(
      Uri.parse('http://${server.address.address}:${server.port}/dav/'),
      authorization: 'Basic test',
    );

    expect(entries.single.isDirectory, isTrue);
  });
}
