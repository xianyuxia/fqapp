import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'sync_document.dart';
import 'sync_transport.dart';
import 'weiyun_hash.dart';

typedef SaveSyncCredentials =
    Future<void> Function(Map<String, String> updates);
SyncTransport createCloudSyncTransport(
  Map<String, String> config,
  SaveSyncCredentials save,
) {
  switch (config['provider']) {
    case 'onedrive':
      return OneDriveSyncTransport(config, save);
    case 'weiyun':
      return WeiyunSyncTransport(config);
    case 'ali':
      return AliSyncTransport(config, save);
    default:
      throw const SyncFailure('该服务的持续同步尚未开放，请先选 WebDAV 或已接入的服务');
  }
}

class CloudHttp {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  Future<({int status, Uint8List bytes})> send(
    String method,
    String address, {
    Map<String, String> headers = const {},
    Uint8List? bytes,
  }) async {
    final uri = Uri.parse(address);
    if (uri.scheme != 'https' || uri.userInfo.isNotEmpty) {
      throw const SyncFailure('云盘返回了不安全的连接');
    }
    try {
      final req = await client
          .openUrl(method, uri)
          .timeout(const Duration(seconds: 30));
      req.followRedirects = false;
      headers.forEach(req.headers.set);
      if (bytes != null) {
        req.contentLength = bytes.length;
        req.add(bytes);
      }
      final response = await req.close().timeout(const Duration(seconds: 45));
      final buffer = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(seconds: 45))) {
        buffer.add(chunk);
        if (buffer.length > syncMaxBytes) throw const SyncFailure('云盘响应超过大小限制');
      }
      // Signed file downloads may redirect to a CDN. Follow without credentials.
      if ([301, 302, 303, 307, 308].contains(response.statusCode) &&
          method == 'GET' &&
          headers.isEmpty) {
        final next = response.headers.value('location');
        if (next != null) {
          return await send(
            'GET',
            uri.resolve(next).toString(),
            headers: {'X-Fqapp-Redirect': '1'},
          );
        }
      }
      return (status: response.statusCode, bytes: buffer.takeBytes());
    } on SyncFailure {
      rethrow;
    } catch (_) {
      throw const SyncFailure('云盘连接失败，请检查网络或重新登录');
    }
  }

  Future<Map<String, dynamic>> json(
    String method,
    String url, {
    Map<String, String> headers = const {},
    Object? body,
  }) async {
    final r = await send(
      method,
      url,
      headers: {'Content-Type': 'application/json', ...headers},
      bytes: body == null
          ? null
          : Uint8List.fromList(utf8.encode(jsonEncode(body))),
    );
    if (r.status < 200 || r.status >= 300) {
      throw SyncFailure('云盘接口请求失败（HTTP ${r.status}），可能需要重新登录');
    }
    try {
      return r.bytes.isEmpty
          ? {}
          : Map<String, dynamic>.from(jsonDecode(utf8.decode(r.bytes)) as Map);
    } catch (_) {
      throw const SyncFailure('云盘返回内容无效');
    }
  }

  void close() => client.close(force: true);
}

String _folder(Map<String, String> config) {
  final folder = config['endpoint']?.trim();
  final name = folder == null || folder.isEmpty ? 'fqappx-sync-v1' : folder;
  if (!RegExp(r'^[a-zA-Z0-9_-]{1,64}$').hasMatch(name)) {
    throw const SyncFailure('云盘同步文件夹请使用 1 至 64 位字母、数字、横线或下划线');
  }
  return name;
}

class OneDriveSyncTransport implements SyncTransport {
  OneDriveSyncTransport(this.config, this.save);
  final Map<String, String> config;
  final SaveSyncCredentials save;
  final http = CloudHttp();
  String access = '', folderId = '';
  static const graph = 'https://graph.microsoft.com/v1.0/me/drive';
  Map<String, String> get headers => {'Authorization': 'Bearer $access'};
  @override
  Future<void> prepare() async {
    String refresh = config['password'] ?? '';
    try {
      final raw = jsonDecode(refresh) as Map;
      refresh = raw['refresh_token'] as String? ?? '';
      access = raw['access_token'] as String? ?? '';
    } catch (_) {}
    if (refresh.isNotEmpty) {
      final url = Uri.https('api.oplist.org', '/onedrive/renewapi', {
        'refresh_ui': refresh,
        'server_use': 'true',
        'driver_txt': 'onedrive_pr',
      });
      final token = await http.json('GET', url.toString());
      access = token['access_token'] as String? ?? '';
      refresh = token['refresh_token'] as String? ?? refresh;
      if (access.isEmpty) throw const SyncFailure('OneDrive 令牌续期失败，请重新授权');
      await save({
        'password': jsonEncode({
          'access_token': access,
          'refresh_token': refresh,
        }),
      });
    }
    if (access.isEmpty) throw const SyncFailure('请先登录 OneDrive 或导入授权结果');
    final name = _folder(config);
    final r = await http.send('GET', '$graph/root:/$name', headers: headers);
    Map item;
    if (r.status == 404) {
      item = await http.json(
        'POST',
        '$graph/root/children',
        headers: headers,
        body: {
          'name': name,
          'folder': {},
          '@microsoft.graph.conflictBehavior': 'fail',
        },
      );
    } else if (r.status == 200) {
      item = jsonDecode(utf8.decode(r.bytes)) as Map;
    } else {
      throw SyncFailure('OneDrive 文件夹读取失败（HTTP ${r.status}）');
    }
    if (item['folder'] is! Map) throw const SyncFailure('OneDrive 同名项目不是文件夹');
    folderId = item['id'] as String;
  }

  String get base => '$graph/items/${Uri.encodeComponent(folderId)}';
  @override
  Future<List<String>> list() async {
    String? url = '$base/children?\$select=name,id&\$top=200';
    final names = <String>[];
    var pages = 0;
    while (url != null) {
      if (++pages > 20 ||
          !url.startsWith('https://graph.microsoft.com/v1.0/')) {
        throw const SyncFailure('OneDrive 列表分页无效');
      }
      final raw = await http.json('GET', url, headers: headers);
      for (final item in raw['value'] as List) {
        final name = item['name'];
        if (name is String && syncSlotPattern.hasMatch(name)) names.add(name);
      }
      url = raw['@odata.nextLink'] as String?;
    }
    return names;
  }

  @override
  Future<Uint8List?> read(String name) async {
    checkSlotName(name);
    // Request metadata first; download URLs are pre-authorized and never receive
    // the Graph bearer token when their host differs from graph.microsoft.com.
    final r = await http.send('GET', '$base:/$name', headers: headers);
    if (r.status == 404) return null;
    if (r.status != 200) throw SyncFailure('OneDrive 文件读取失败（HTTP ${r.status}）');
    final item = jsonDecode(utf8.decode(r.bytes)) as Map;
    final url = item['@microsoft.graph.downloadUrl'];
    if (url is! String) throw const SyncFailure('OneDrive 未返回下载地址');
    final file = await http.send('GET', url);
    if (file.status != 200) throw const SyncFailure('OneDrive 下载失败');
    return file.bytes;
  }

  @override
  Future<void> write(String name, Uint8List bytes) async {
    checkSlotName(name);
    final r = await http.send(
      'PUT',
      '$base:/$name:/content',
      headers: {...headers, 'Content-Type': 'application/json'},
      bytes: bytes,
    );
    if (![200, 201].contains(r.status)) {
      throw SyncFailure('OneDrive 写入失败（HTTP ${r.status}）');
    }
  }

  @override
  void close() => http.close();
}

class WeiyunSyncTransport implements SyncTransport {
  WeiyunSyncTransport(this.config);
  final Map<String, String> config;
  final http = CloudHttp();
  String parent = '', directory = '';
  int request = 0;
  String get token {
    final text = config['password'] ?? '';
    final found = RegExp(
      r'(?:WEIYUN_)?MCP_TOKEN\s*[=:]\s*["\x27]?([A-Za-z0-9_.-]{16,2048})(?=["\x27\s;]|$)',
      caseSensitive: false,
    ).firstMatch(text);
    final value = found?.group(1) ?? text.trim();
    if (!RegExp(r'^[A-Za-z0-9_.-]{16,2048}$').hasMatch(value)) {
      throw const SyncFailure('未识别到微云 MCP Token，请粘贴官方安装指令');
    }
    return value;
  }

  Future<Map<String, dynamic>> call(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    final result = await http.json(
      'POST',
      'https://www.weiyun.com/api/v3/mcpserver',
      headers: {'WyHeader': 'mcp_token=$token'},
      body: {
        'jsonrpc': '2.0',
        'id': ++request,
        'method': 'tools/call',
        'params': {'name': 'weiyun.$name', 'arguments': arguments},
      },
    );
    if (result['error'] != null) throw const SyncFailure('微云授权或接口请求失败');
    final envelope = result['result'] as Map;
    if (envelope['isError'] == true) {
      throw const SyncFailure('微云拒绝请求，请检查授权目录和 Token');
    }
    for (final item in envelope['content'] as List) {
      if (item['type'] != 'text') continue;
      final data = Map<String, dynamic>.from(
        jsonDecode(item['text'] as String) as Map,
      );
      if ((data['error']?.toString() ?? '').isNotEmpty ||
          (data['code'] != null && data['code'] != 0)) {
        throw const SyncFailure('微云操作失败，请检查 Token 和文件权限');
      }
      return data;
    }
    throw const SyncFailure('微云响应无效');
  }

  Future<List<Map<String, dynamic>>> entries({bool root = false}) async {
    final all = <Map<String, dynamic>>[];
    for (var offset = 0; offset < 10000; offset += 200) {
      final r = await call('list', {
        'limit': 200,
        'offset': offset,
        'get_type': 0,
        if (!root) 'dir_key': directory,
        if (!root) 'pdir_key': parent,
      });
      if (root) parent = r['pdir_key'] as String? ?? '';
      final dirs = (r['dir_list'] as List? ?? []).cast<Map>();
      final files = (r['file_list'] as List? ?? []).cast<Map>();
      all.addAll([...dirs, ...files].map((e) => Map<String, dynamic>.from(e)));
      if (dirs.length + files.length < 200) return all;
    }
    throw const SyncFailure('微云授权目录项目过多，请选择专用目录');
  }

  @override
  Future<void> prepare() async {
    final roots = await entries(root: true);
    final name = _folder(config);
    final existing = roots.where((e) => e['dir_name'] == name).toList();
    if (existing.length > 1) throw const SyncFailure('微云存在重名同步文件夹，请更换目录名');
    directory = existing.isEmpty
        ? (await call('create_dir', {
                'pdir_key': parent,
                'dir_name': name,
              }))['dir_key']
              as String
        : existing.single['dir_key'] as String;
    if (parent.isEmpty || directory.isEmpty) {
      throw const SyncFailure('微云未授予文件目录权限');
    }
  }

  @override
  Future<List<String>> list() async => (await entries())
      .map((e) => e['filename'])
      .whereType<String>()
      .where(syncSlotPattern.hasMatch)
      .toList();
  @override
  Future<Uint8List?> read(String name) async {
    checkSlotName(name);
    final matches = (await entries())
        .where((e) => e['filename'] == name)
        .toList();
    if (matches.isEmpty) return null;
    if (matches.length > 1) throw const SyncFailure('微云产生了重名快照，暂停同步以避免覆盖');
    final r = await call('download', {
      'items': [
        {'file_id': matches.single['file_id'], 'pdir_key': directory},
      ],
    });
    final item = (r['items'] as List).first as Map;
    final response = await http.send(
      'GET',
      item['https_download_url'] as String,
      headers: {'Cookie': item['cookie'] as String? ?? ''},
    );
    if (response.status != 200) throw const SyncFailure('微云快照下载失败');
    return response.bytes;
  }

  @override
  Future<void> write(String name, Uint8List bytes) async {
    checkSlotName(name);
    final hashes = weiyunUploadHashes(bytes);
    final pre = {
      'filename': name,
      'file_size': bytes.length,
      'pdir_key': directory,
      ...hashes,
    };
    for (var round = 0; round < 512; round++) {
      final r = await call('upload', pre);
      if (r['file_exist'] == true || r['upload_state'] == 2) return;
      final channels = r['channel_list'] as List? ?? [];
      final writable = channels
          .cast<Map>()
          .where((c) => (c['len'] as num) > 0)
          .toList();
      if (writable.isEmpty) throw const SyncFailure('微云未返回上传通道');
      final channel = writable.first;
      final offset = channel['offset'] as int;
      final end = min(bytes.length, offset + (channel['len'] as int));
      if (offset < 0 || end <= offset) throw const SyncFailure('微云上传范围无效');
      final sent = await call('upload', {
        'filename': name,
        'file_size': bytes.length,
        'file_sha': hashes['file_sha'],
        'block_sha_list': [],
        'check_sha': hashes['check_sha'],
        'upload_key': r['upload_key'],
        'channel_list': channels,
        'channel_id': channel['id'],
        'ex': r['ex'],
        'file_data': base64Encode(bytes.sublist(offset, end)),
      });
      if (sent['upload_state'] == 2) return;
    }
    throw const SyncFailure('微云上传尚未完成');
  }

  @override
  void close() => http.close();
}

class AliSyncTransport implements SyncTransport {
  AliSyncTransport(this.config, this.save);
  final Map<String, String> config;
  final SaveSyncCredentials save;
  final http = CloudHttp();
  String access = '', drive = '', directory = '';
  Map<String, String> get headers => {
    'Authorization': 'Bearer $access',
    'Origin': 'https://www.alipan.com',
    'Referer': 'https://www.alipan.com/',
  };
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body,
  ) async {
    final result = await http.json(
      'POST',
      'https://api.alipan.com$path',
      headers: headers,
      body: body,
    );
    if (result['code'] != null) throw const SyncFailure('阿里云盘接口拒绝请求，请重新登录');
    return result;
  }

  Future<List<Map<String, dynamic>>> entries(String parent) async {
    final entries = <Map<String, dynamic>>[];
    String marker = '';
    for (var page = 0; page < 50; page++) {
      final r = await post('/v2/file/list', {
        'drive_id': drive,
        'parent_file_id': parent,
        'limit': 200,
        'marker': marker,
        'order_by': 'name',
        'order_direction': 'ASC',
      });
      entries.addAll(
        (r['items'] as List).map((e) => Map<String, dynamic>.from(e as Map)),
      );
      marker = r['next_marker'] as String? ?? '';
      if (marker.isEmpty) return entries;
    }
    throw const SyncFailure('阿里目录项目过多，请选择专用同步目录');
  }

  @override
  Future<void> prepare() async {
    Map token;
    try {
      token = jsonDecode(config['password'] ?? '') as Map;
    } catch (_) {
      throw const SyncFailure('请先通过阿里云盘网页登录');
    }
    access = token['access_token'] as String? ?? '';
    final refresh = token['refresh_token'] as String?;
    if (refresh != null && refresh.isNotEmpty) {
      final r = await http.json(
        'POST',
        'https://auth.alipan.com/v2/account/token',
        body: {'refresh_token': refresh, 'grant_type': 'refresh_token'},
      );
      if (r['access_token'] is! String) throw const SyncFailure('阿里登录失效，请重新登录');
      access = r['access_token'] as String;
      await save({'password': jsonEncode(r)});
    }
    drive = (await post('/v2/user/get', {}))['default_drive_id'] as String;
    final name = _folder(config);
    final folders = (await entries(
      'root',
    )).where((e) => e['name'] == name).toList();
    if (folders.length > 1) throw const SyncFailure('阿里存在重名同步目录');
    if (folders.isNotEmpty && folders.single['type'] != 'folder') {
      throw const SyncFailure('同名项目不是文件夹');
    }
    directory = folders.isEmpty
        ? (await post('/adrive/v2/file/createWithFolders', {
                'drive_id': drive,
                'parent_file_id': 'root',
                'name': name,
                'type': 'folder',
                'check_name_mode': 'refuse',
              }))['file_id']
              as String
        : folders.single['file_id'] as String;
  }

  @override
  Future<List<String>> list() async => (await entries(directory))
      .map((e) => e['name'])
      .whereType<String>()
      .where(syncSlotPattern.hasMatch)
      .toList();
  @override
  Future<Uint8List?> read(String name) async {
    checkSlotName(name);
    final files = (await entries(
      directory,
    )).where((e) => e['name'] == name).toList();
    if (files.isEmpty) return null;
    if (files.length > 1) throw const SyncFailure('阿里产生重名快照，已暂停同步');
    final url =
        (await post('/v2/file/get_download_url', {
              'drive_id': drive,
              'file_id': files.single['file_id'],
              'expire_sec': 600,
            }))['url']
            as String;
    final r = await http.send(
      'GET',
      url,
      headers: {'Referer': 'https://www.alipan.com/'},
    );
    if (r.status != 200) throw const SyncFailure('阿里快照下载失败');
    return r.bytes;
  }

  @override
  Future<void> write(String name, Uint8List bytes) async {
    checkSlotName(name);
    // Overwrite only the inactive fixed slot. Never implement repeated sync by
    // trashing and recreating files: that would grow the user's recycle bin.
    final prior = (await entries(
      directory,
    )).where((e) => e['name'] == name).toList();
    if (prior.length > 1) throw const SyncFailure('阿里存在重名快照，已暂停同步');
    final created = await post('/adrive/v2/file/createWithFolders', {
      'drive_id': drive,
      'parent_file_id': directory,
      'name': name,
      'type': 'file',
      'size': bytes.length,
      'check_name_mode': 'overwrite',
      'content_hash_name': 'none',
      'proof_version': 'v1',
      'part_info_list': [
        {'part_number': 1},
      ],
    });
    if (created['rapid_upload'] != true) {
      final parts = created['part_info_list'] as List;
      if (parts.length != 1) throw const SyncFailure('阿里返回了不支持的上传分片');
      final r = await http.send(
        'PUT',
        parts.single['upload_url'] as String,
        bytes: bytes,
      );
      if (r.status < 200 || r.status >= 300) {
        throw const SyncFailure('阿里快照上传失败');
      }
      await post('/v2/file/complete', {
        'drive_id': drive,
        'file_id': created['file_id'],
        'upload_id': created['upload_id'],
      });
    }
  }

  @override
  void close() => http.close();
}
