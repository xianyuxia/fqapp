import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'backend_transport_common.dart';

@JS('shijinpuCore')
external JSPromise<_CoreReply> _callCore(
  JSString relay,
  JSString? path,
  JSString query,
);

extension type _CoreReply(JSObject _) implements JSObject {
  external JSNumber get status;
  external JSString get contentType;
  external JSUint8Array get body;
}

class BackendService {
  static final instance = BackendService();

  final _WebBackendTransport _transport = _WebBackendTransport();
  Future<void>? _starting;
  bool _running = false;

  BackendTransport get transport => _transport;
  String get baseUrl => transport.baseUrl;
  bool get usesRustTransport => true;
  bool get isRunning => _running;
  List<String> get logLines => const [];

  Future<void> start() {
    return _starting ??= _start();
  }

  Future<void> _start() async {
    try {
      await _callCore(_transport.relay.toJS, null, ''.toJS).toDart;
      _running = true;
    } catch (_) {
      _starting = null;
      rethrow;
    }
  }

  void cancelStartupTimeout() {}
  Future<void> stop() async {}
  Future<void> restartForListenMode() => start();
  Future<void> restartForConfiguration() => start();
  Future<String?> readRustLog() async => null;
}

class _WebBackendTransport extends BackendTransport {
  final String relay = const String.fromEnvironment(
    'SHIJINPU_RELAY_URL',
    defaultValue: '/relay',
  );

  @override
  String get baseUrl => Uri.base.origin;

  @override
  Future<BackendResponse> send(
    String method,
    Uri url, {
    Uint8List? body,
    Duration? timeout,
    BackendRequest? request,
  }) async {
    if (request?.isCancelled == true) {
      throw BackendRequestAborted('请求已取消');
    }
    if (method != 'GET' || body != null) {
      throw UnsupportedError('此操作暂不支持网页版');
    }
    final reply = _callCore(relay.toJS, url.path.toJS, url.query.toJS).toDart;
    final responseFuture = request == null
        ? reply
        : Future.any([
            reply,
            request.whenCancelled.then<_CoreReply>(
              (_) => throw BackendRequestAborted('请求已取消'),
            ),
          ]);
    final response = timeout == null
        ? await responseFuture
        : await responseFuture.timeout(
            timeout,
            onTimeout: () =>
                throw BackendRequestAborted('请求超时', timedOut: true),
          );
    return BackendResponse(
      response.status.toDartInt,
      response.body.toDart,
      response.contentType.toDart,
    );
  }
}
