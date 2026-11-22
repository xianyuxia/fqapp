import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// One backend response.
///
/// The transport keeps the HTTP shape (status + bytes) because the whole
/// business contract - including "HTTP 200 with a business error code" - is
/// expressed that way by the Rust core.
class BackendResponse {
  const BackendResponse(this.statusCode, this.body, this.contentType);

  final int statusCode;
  final Uint8List body;
  final String contentType;
}

/// Raised when a call was cancelled, or exceeded its deadline.
///
/// Cancelling drops the in-flight Rust dispatch future, which tears down the
/// awaiting upstream request, any retry backoff and any not-yet-submitted
/// write - so a late result is never published. A filesystem write the OS has
/// already accepted is not rolled back: Tokio file I/O is not a transaction.
class BackendRequestAborted implements Exception {
  BackendRequestAborted(
    this.message, {
    this.timedOut = false,
    this.fatal = false,
  });

  final String message;

  /// The request hit its deadline instead of the caller cancelling. A shared
  /// caller may retry only when it has its own explicitly remaining budget.
  final bool timedOut;

  /// The failure is final: retrying the same request cannot change it.
  ///
  /// The local core refusing to start is the case that matters - retrying
  /// only replays the same startup failure, so the request gate must not
  /// treat it as retryable (#318).
  final bool fatal;

  @override
  String toString() => message;
}

/// Cancellation handle for one logical unit of work.
///
/// A page (or a feed loader) creates one, asks [ApiClient.withCancellation] to
/// bind its requests to it, and cancels it when the page goes away or a newer
/// request supersedes it. Cancelling is idempotent and always safe.
class BackendRequest {
  final List<void Function()> _cancellers = [];
  bool _cancelled = false;
  final Completer<void> _cancelledSignal = Completer<void>();

  bool get isCancelled => _cancelled;

  /// Completes when [cancel] is called. A request that is already cancelled
  /// resolves immediately.
  Future<void> get whenCancelled => _cancelledSignal.future;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _cancelledSignal.complete();
    for (final cancel in List<void Function()>.of(_cancellers)) {
      cancel();
    }
    _cancellers.clear();
  }

  /// Registers [cancel]. Returns false - after cancelling immediately - when
  /// this request was already cancelled, which is how a caller that lost a race
  /// learns it must not start the work at all.
  bool register(void Function() cancel) {
    if (_cancelled) {
      cancel();
      return false;
    }
    _cancellers.add(cancel);
    return true;
  }

  void unregister(void Function() cancel) {
    _cancellers.remove(cancel);
  }
}

/// [baseUrl] with [capability] woven into the path, ending in `/`.
///
/// Resource URLs must use this: backend-relative paths are root-relative
/// (`/src/...`) and `Uri.resolve` would otherwise replace the whole base path,
/// dropping the capability. `resolveBackendResource` re-anchors them.
///
/// A free function rather than an interface member, so that every
/// `implements BackendTransport` (test doubles included) stays untouched.
String backendResourceBase(String baseUrl, String capability) =>
    capability.isEmpty ? '$baseUrl/' : '$baseUrl/_session/$capability/';

/// A backend call surface. Two implementations share the same Rust core:
/// [RustBackendTransport] calls it over flutter_rust_bridge, and
/// [HttpBackendTransport] talks to the loopback HTTP adapter (tests, desktop,
/// Web).
abstract class BackendTransport {
  /// Base URL used to resolve backend-relative resources such as `/src/...`.
  String get baseUrl;

  /// Per-launch capability the loopback adapter requires; empty when unknown.
  ///
  /// Only callers that cross the socket must present it - FFI calls stay in
  /// process and are never gated.
  String get capability => '';

  Future<BackendResponse> send(
    String method,
    Uri url, {
    Uint8List? body,
    Duration? timeout,
    BackendRequest? request,
  });

  Future<void> close() async {}
}

class HttpBackendTransport implements BackendTransport {
  HttpBackendTransport({
    http.Client? client,
    required this.baseUrl,
    this.capability = '',
  }) : _client = client ?? http.Client();

  final http.Client _client;

  @override
  final String baseUrl;

  /// Loopback capability presented as a bearer token; empty when the caller
  /// talks to a server that does not ask for one.
  ///
  /// Mutable because the FFI transport only learns it once the core is up.
  @override
  String capability;

  @override
  Future<BackendResponse> send(
    String method,
    Uri url, {
    Uint8List? body,
    Duration? timeout,
    BackendRequest? request,
  }) async {
    if (request != null && request.isCancelled) {
      throw BackendRequestAborted('请求已取消');
    }
    final abort = Completer<void>();
    void abortNow() {
      if (!abort.isCompleted) abort.complete();
    }

    if (request != null && !request.register(abortNow)) {
      throw BackendRequestAborted('请求已取消');
    }

    final httpRequest = http.AbortableRequest(
      method,
      url,
      abortTrigger: abort.future,
    );
    if (body != null) httpRequest.bodyBytes = body;
    if (capability.isNotEmpty) {
      // This is the only HTTP path that never sees the cookie the entry URL
      // sets, so it has to present the capability as a bearer token.
      httpRequest.headers['authorization'] = 'Bearer $capability';
    }
    try {
      // The deadline must cover reading the body too: a server that sends
      // headers and then stalls would otherwise hold the connection forever.
      final response = await _client
          .send(httpRequest)
          .then(http.Response.fromStream)
          .timeout(timeout ?? const Duration(seconds: 20));
      return BackendResponse(
        response.statusCode,
        response.bodyBytes,
        response.headers['content-type'] ?? '',
      );
    } catch (error) {
      // A timed-out or cancelled exchange must not keep occupying a connection.
      abortNow();
      if (request != null &&
          request.isCancelled &&
          error is! BackendRequestAborted) {
        throw BackendRequestAborted('请求已取消');
      }
      rethrow;
    } finally {
      request?.unregister(abortNow);
    }
  }

  @override
  Future<void> close() async {
    _client.close();
  }
}
