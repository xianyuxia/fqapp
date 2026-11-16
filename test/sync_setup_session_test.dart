import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/sync/sync_setup_session.dart';
import 'package:fqapp/services/sync/sync_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'WebDAV login and directory browsing never create or write; only explicit create makes a directory',
    () async {
      HttpOverrides.global = null;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final methods = <String>[];
      var created = false;
      final subscription = server.listen((request) async {
        methods.add(request.method);
        expect(request.headers.value('Authorization'), 'Basic dXNlcjpwYXNz');
        if (request.method == 'PROPFIND') {
          request.response.statusCode = 207;
          request.response.write(
            '<d:multistatus xmlns:d="DAV:">'
            '<d:response><d:href>/dav/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>'
            '<d:response><d:href>/dav/keep/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>'
            '<d:response><d:href>https://other.invalid/stolen/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>'
            '<d:response><d:href>/dav/readme.txt</d:href><d:propstat><d:prop><d:resourcetype/></d:prop></d:propstat></d:response>'
            '</d:multistatus>',
          );
        } else if (request.method == 'MKCOL') {
          expect(Uri.decodeComponent(request.uri.path), '/dav/阅读同步/');
          created = true;
          request.response.statusCode = 201;
        } else {
          request.response.statusCode = 405;
        }
        await request.response.close();
      });
      final session = await openSyncSetup({
        'provider': 'webdav',
        'endpoint': 'http://127.0.0.1:${server.port}/dav/',
        'username': 'user',
        'password': 'pass',
      });
      try {
        final folders = await session.folders(session.root);
        expect(folders.map((f) => f.name), ['keep']);
        expect(methods, ['PROPFIND']);
        expect(created, false);
        final folder = await session.createFolder(session.root, '阅读同步');
        expect(created, true);
        expect(
          Uri.decodeComponent(
            Uri.parse(session.select(folder)['endpoint']!).path,
          ),
          '/dav/阅读同步/',
        );
        expect(methods.where((method) => method == 'PUT'), isEmpty);
      } finally {
        session.close();
        await subscription.cancel();
        await server.close(force: true);
      }
    },
  );
  test('invalid directory names are rejected before network operations', () {
    for (final name in ['', '..', '../other', 'a/b', 'a\\b', 'a\nb']) {
      expect(() => validateSyncFolderName(name), throwsA(isA<SyncFailure>()));
    }
    expect(() => validateSyncFolderName('阅读同步'), returnsNormally);
  });
}
