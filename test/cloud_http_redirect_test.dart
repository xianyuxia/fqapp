import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/sync/cloud_sync_transport.dart';
import 'package:fqapp/services/sync/sync_transport.dart';

class _Headers implements HttpHeaders {
  final values = <String, String>{};
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      values[name.toLowerCase()] = value.toString();
  @override
  String? value(String name) => values[name.toLowerCase()];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(this.statusCode, {String? location, this.body = 'probe'}) {
    if (location != null) headers.set('location', location);
  }
  @override
  final int statusCode;
  final String body;
  @override
  final headers = _Headers();
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream.value(utf8.encode(body)).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request implements HttpClientRequest {
  _Request(this.response, {this.respond});
  final _Response response;
  final _Response Function(List<int>)? respond;
  final body = <int>[];
  @override
  final headers = _Headers();
  @override
  bool followRedirects = true;
  @override
  int contentLength = -1;
  @override
  void add(List<int> data) => body.addAll(data);
  @override
  Future<HttpClientResponse> close() async => respond?.call(body) ?? response;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client implements HttpClient {
  _Client(this.respond, {this.respondBody});
  final _Response Function(Uri) respond;
  final _Response Function(Uri, List<int>)? respondBody;
  final requests = <_Request>[];
  @override
  Duration? connectionTimeout;
  @override
  Future<HttpClientRequest> openUrl(String method, Uri uri) async {
    final request = _Request(
      respond(uri),
      respond: respondBody == null ? null : (bytes) => respondBody!(uri, bytes),
    );
    requests.add(request);
    return request;
  }

  @override
  void close({bool force = false}) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Overrides extends HttpOverrides {
  _Overrides(this.client);
  final _Client client;
  @override
  HttpClient createHttpClient(SecurityContext? context) => client;
}

void main() {
  tearDown(() => HttpOverrides.global = null);
  test('Weiyun caps pages at 50 and accepts string success codes', () async {
    const slot = '11111111111111111111111111111111.a.json';
    final offsets = <int>[];
    final client = _Client(
      (_) => _Response(200),
      respondBody: (uri, bytes) {
        final request = jsonDecode(utf8.decode(bytes)) as Map;
        final params = request['params'] as Map;
        expect(params['name'], 'weiyun.list');
        final args = params['arguments'] as Map;
        expect(args['limit'], 50);
        final root = args['dir_key'] == null;
        final offset = args['offset'] as int;
        if (root) offsets.add(offset);
        final data = {
          'code': '0',
          'error': null,
          'pdir_key': 'unit-parent',
          'dir_list': root
              ? offset == 0
                    ? List.generate(
                        50,
                        (i) => {'dir_name': 'unit-$i', 'dir_key': 'unit-$i'},
                      )
                    : [
                        {'dir_name': 'fqappx-sync-v1', 'dir_key': 'unit-dir'},
                      ]
              : [],
          'file_list': root
              ? []
              : [
                  {'filename': slot, 'file_id': 'unit-file'},
                ],
          'finish_flag': !root || offset == 50 ? 1 : 0,
        };
        return _Response(
          200,
          body: jsonEncode({
            'result': {
              'content': [
                {'type': 'text', 'text': jsonEncode(data)},
              ],
            },
          }),
        );
      },
    );
    HttpOverrides.global = _Overrides(client);
    final transport = WeiyunSyncTransport({'password': 'unit-test-grant-0000'});
    await transport.prepare();
    expect(await transport.list(), [slot]);
    expect(offsets, [0, 50]);
    transport.close();
  });
  test(
    'Ali downloads use the signed legacy Referer without API credentials',
    () async {
      const slot = '11111111111111111111111111111111.a.json';
      final client = _Client(
        (uri) => switch (uri.path) {
          '/v2/user/get' => _Response(
            200,
            body: jsonEncode({'default_drive_id': 'unit-drive'}),
          ),
          '/v2/file/list' => _Response(
            200,
            body: jsonEncode({
              'items': [
                {
                  'name': 'fqappx-sync-v1',
                  'type': 'folder',
                  'file_id': 'unit-folder',
                },
                {'name': slot, 'type': 'file', 'file_id': 'unit-file'},
              ],
              'next_marker': '',
            }),
          ),
          '/v2/file/get_download_url' => _Response(
            200,
            body: jsonEncode({'url': 'https://cdn.example.test/file'}),
          ),
          _ => _Response(200),
        },
      );
      HttpOverrides.global = _Overrides(client);
      final transport = AliSyncTransport({
        'password': jsonEncode({'access_token': 'unit-test-only'}),
      }, (_) async {});
      await transport.prepare();
      expect(utf8.decode((await transport.read(slot))!), 'probe');
      final download = client.requests.last.headers;
      expect(download.value('referer'), 'https://www.aliyundrive.com/');
      expect(download.value('authorization'), isNull);
      expect(download.value('content-type'), isNull);
      transport.close();
    },
  );
  test(
    'download redirects retain same-origin grants and strip them at a CDN',
    () async {
      final client = _Client(
        (uri) => switch (uri.path) {
          '/start' => _Response(302, location: '/next'),
          '/next' => _Response(307, location: 'https://cdn.example.test/file'),
          _ => _Response(200),
        },
      );
      HttpOverrides.global = _Overrides(client);
      final http = CloudHttp();
      final result = await http.send(
        'GET',
        'https://drive.example.test/start',
        headers: {
          'Authorization': 'Bearer unit-test-only',
          'Cookie': 'unit-test-only=true',
          'Referer': 'https://drive.example.test/',
          'Range': 'bytes=0-4',
        },
      );
      expect(result.status, 200);
      expect(utf8.decode(result.bytes), 'probe');
      expect(
        client.requests[1].headers.value('authorization'),
        'Bearer unit-test-only',
      );
      expect(client.requests[1].headers.value('cookie'), 'unit-test-only=true');
      final cdn = client.requests[2].headers;
      expect(cdn.value('authorization'), isNull);
      expect(cdn.value('cookie'), isNull);
      expect(cdn.value('referer'), 'https://drive.example.test/');
      expect(cdn.value('range'), 'bytes=0-4');
      http.close();
    },
  );
  test('redirect loops terminate and HTTPS cannot downgrade', () async {
    final loop = _Client((uri) => _Response(302, location: '/loop'));
    HttpOverrides.global = _Overrides(loop);
    final http = CloudHttp();
    await expectLater(
      http.send('GET', 'https://drive.example.test/loop'),
      throwsA(isA<SyncFailure>()),
    );
    expect(loop.requests.length, 6);
    http.close();
    final downgrade = _Client(
      (uri) => _Response(302, location: 'http://cdn.example.test/file'),
    );
    HttpOverrides.global = _Overrides(downgrade);
    final secure = CloudHttp();
    await expectLater(
      secure.send('GET', 'https://drive.example.test/start'),
      throwsA(isA<SyncFailure>()),
    );
    expect(downgrade.requests.length, 1);
    secure.close();
  });
}
