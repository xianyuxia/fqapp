import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/sync/sync_folder_name.dart';
import 'package:fqapp/services/sync/sync_setup_session.dart';
import 'package:fqapp/services/sync/sync_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'WebDAV login and directory browsing never create or write; only explicit create makes a directory',
    () async {
      final tls = SecurityContext()
        ..useCertificateChainBytes(utf8.encode(_certificate))
        ..usePrivateKeyBytes(utf8.encode(_privateKey));
      final server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        tls,
      );
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
      final session = await HttpOverrides.runWithHttpOverrides(
        () => openSyncSetup({
          'provider': 'webdav',
          'endpoint': 'https://127.0.0.1:${server.port}/dav/',
          'username': 'user',
          'password': 'pass',
        }),
        _TrustLoopbackCertificate(),
      );
      try {
        expect(
          session.select(session.root)['endpoint'],
          'https://127.0.0.1:${server.port}/dav/',
        );
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
  test('WebDAV requires HTTPS before opening the connection', () async {
    await expectLater(
      openSyncSetup({
        'provider': 'webdav',
        'endpoint': 'http://127.0.0.1/dav/',
        'username': 'reader',
        'password': 'unused',
      }),
      throwsA(isA<SyncFailure>()),
    );
  });

  test('invalid directory names are rejected before network operations', () {
    for (final name in ['', '..', '../other', 'a/b', 'a\\b', 'a\nb']) {
      expect(() => validateSyncFolderName(name), throwsA(isA<SyncFailure>()));
    }
    expect(() => validateSyncFolderName('阅读同步'), returnsNormally);
  });
}

class _TrustLoopbackCertificate extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(
        SecurityContext(withTrustedRoots: false)
          ..setTrustedCertificatesBytes(utf8.encode(_certificate)),
      );
}

// Self-signed test-only fixture for the 127.0.0.1 HTTPS server.
const _certificate = '''
-----BEGIN CERTIFICATE-----
MIIBUjCB+aADAgECAhQY40ebS2n2mpDLLhv98UHqbOwFCzAKBggqhkjOPQQDAjAU
MRIwEAYDVQQDDAkxMjcuMC4wLjEwIBcNMjAwMTAxMDAwMDAwWhgPMjA5OTAxMDEw
MDAwMDBaMBQxEjAQBgNVBAMMCTEyNy4wLjAuMTBZMBMGByqGSM49AgEGCCqGSM49
AwEHA0IABNRNtQ45bneKBjTdYbaixzSwAPaiYBVJ+tSWzUvGXBW8w6TDuShVwU+u
/CRC86wcmv0ztSYUYoMH/cYs9nIAo1GjJzAlMA8GA1UdEQQIMAaHBH8AAAEwEgYD
VR0TAQH/BAgwBgEB/wIBADAKBggqhkjOPQQDAgNIADBFAiEAlwtVobng+kJ5qHqW
spNzw36TUo+Gag74Nnn2MSFWL2YCIDMkXxORYo4/ASesIm+ydgPZ4zvP6jl84vED
2WK6dmUn
-----END CERTIFICATE-----
''';
const _privateKey = '''
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgwO1kEhO/bhu28zYp
tsuuQJ/zvQtJxH45nt0t7GF0EyOhRANCAATUTbUOOW53igY03WG2osc0sAD2omAV
SfrUls1LxlwVvMOkw7koVcFPrvwkQvOsHJr9M7UmFGKDB/3GLPZyAKNR
-----END PRIVATE KEY-----
''';
