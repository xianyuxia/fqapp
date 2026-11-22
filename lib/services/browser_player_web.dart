import 'dart:async';
import 'dart:js_interop';
import 'dart:html' as html;
import 'dart:ui_web' as ui;
import 'package:flutter/rendering.dart' show PlatformViewHitTestBehavior;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'platform_channel.dart';
import 'browser_speech_web.dart';

const browserMediaAvailable = true;
const _channel = 'fqapp/native_player';
final _events = StreamController<dynamic>.broadcast();
final _players = <int, html.VideoElement>{};
int _nextId = 0;
final _jobs = <int, html.Worker>{};
final _urls = <int, String>{};
final _playRequested = <int>{};
final _rangeFallbacks = <int>{};
final _rangeStartupTimers = <int, Timer>{};
const _view = 'fq-browser-media';

@JS('shijinpuOpenMediaRange')
external JSPromise<JSString> _openMediaRange(
  JSString url,
  JSString key,
  JSBoolean audioOnly,
);

@JS('shijinpuCloseMediaRange')
external void _closeMediaRange(JSString path);

@JS('shijinpuOpenMediaRange')
external JSFunction? get _rangeDriver;
final _rangeUrls = <int, String>{};

Widget browserVideo(int id) => HtmlElementView(
  key: ValueKey(id),
  viewType: _view,
  creationParams: id,
  hitTestBehavior: PlatformViewHitTestBehavior.transparent,
);

Future<bool> openBrowserVideoFullscreen(int? id) async {
  final video = _players[id];
  if (video == null) return false;
  video.controls = true;
  video.style.pointerEvents = 'auto';
  try {
    if (html.document.fullscreenEnabled == true) {
      await video.requestFullscreen();
    } else {
      // iOS Safari exposes fullscreen on the video element itself.
      video.enterFullscreen();
    }
    return true;
  } catch (_) {
    _restoreInlineVideo(video);
    return false;
  }
}

void _restoreInlineVideo(html.VideoElement video) {
  video.controls = false;
  video.style.pointerEvents = 'none';
}

void installBrowserMedia() {
  ui.platformViewRegistry.registerViewFactory(
    _view,
    (int viewId, {Object? params}) => _players[params]!,
  );
  PlatformChannels.events = (name) => name == '$_channel/events'
      ? _events.stream
      : name == 'fqapp/system_tts_events'
      ? browserSpeechEvents.stream
      : EventChannel(name).receiveBroadcastStream();
  PlatformChannels.invoke = (channel, method, args) async {
    if (channel == 'fqapp/system_tts') return browserSpeech(method, args);
    if (channel != _channel)
      return MethodChannel(channel).invokeMethod(method, args);
    if (method == 'create') return _create(Map.from(args as Map));
    final id = args is Map ? args['id'] as int? : null;
    final media = _players[id];
    switch (method) {
      case 'play':
        _playRequested.add(id!);
        if (_rangeFallbacks.contains(id)) return null;
        try {
          await media!.play();
        } catch (_) {
          if (!_rangeFallbacks.contains(id)) rethrow;
        }
        return null;
      case 'pause':
        _playRequested.remove(id);
        media!.pause();
        return null;
      case 'seek':
        media!.currentTime = (args['positionMs'] as num) / 1000;
        return null;
      case 'setRate':
        media!.playbackRate = args['rate'];
        return null;
      case 'setVolume':
        media!.volume = args['volume'];
        return null;
      case 'dispose':
        if (media != null) {
          _jobs.remove(id)?.terminate();
          _rangeStartupTimers.remove(id)?.cancel();
          _playRequested.remove(id);
          _rangeFallbacks.remove(id);
          final rangeUrl = _rangeUrls.remove(id);
          if (rangeUrl != null) _closeMediaRange(rangeUrl.toJS);
          final objectUrl = _urls.remove(id);
          if (objectUrl != null) html.Url.revokeObjectUrl(objectUrl);
          _players.remove(id);
          media.pause();
          media.removeAttribute('src');
          media.load();
          media.remove();
        }
        return null;
      case 'canDrawOverlays':
      case 'requestOverlayPermission':
        return false;
      case 'setKeepScreenOn':
      case 'startListenForeground':
      case 'stopListenForeground':
      case 'stopFloating':
        return null;
      default:
        throw MissingPluginException(
          'Unsupported browser player method $method',
        );
    }
  };
}

Map<String, int> _create(Map args) {
  final key = args['keyHex'] as String? ?? '';
  final id = ++_nextId;
  final media = html.VideoElement()
    ..setAttribute('playsinline', '')
    ..preload = 'auto';
  _players[id] = media;
  media.style
    ..width = '100%'
    ..height = '100%'
    ..objectFit = 'contain'
    ..pointerEvents = 'none';
  void emit(String type, [Object? value]) {
    if (_players.containsKey(id))
      _events.add({'type': type, 'playerId': id, 'value': value});
  }

  var start = (args['startPositionMs'] as num? ?? 0) / 1000;
  var created = false;
  void markCreated() {
    if (created) return;
    created = true;
    emit('created', id);
  }

  media.onFullscreenChange.listen((_) {
    if (html.document.fullscreenElement != media) _restoreInlineVideo(media);
  });
  media.on['webkitendfullscreen'].listen((_) => _restoreInlineVideo(media));
  media.onLoadedMetadata.listen((_) {
    if (start > 0 && start < media.duration) media.currentTime = start;
    if (media.duration.isFinite)
      emit('duration', (media.duration * 1000).round());
    _events.add({
      'type': 'videoSize',
      'playerId': id,
      'width': media.videoWidth,
      'height': media.videoHeight,
    });
  });
  media.onLoadedData.listen((_) {
    _rangeStartupTimers.remove(id)?.cancel();
    emit('firstFrame');
    emit('buffering', false);
    if (_rangeFallbacks.remove(id) && _playRequested.contains(id)) {
      unawaited(
        media.play().then<void>(
          (_) {},
          onError: (Object _) {
            emit('playing', false);
          },
        ),
      );
    }
  });
  media.onTimeUpdate.listen(
    (_) => emit('position', (media.currentTime * 1000).round()),
  );
  media.onPlaying.listen((_) {
    emit('buffering', false);
    emit('playing', true);
  });
  media.onPause.listen((_) => emit('playing', false));
  media.onWaiting.listen((_) => emit('buffering', true));
  media.onEnded.listen((_) {
    emit('playing', false);
    emit('completed', true);
  });
  void startBlobWorker() {
    if (!_players.containsKey(id)) return;
    try {
      final worker = html.Worker('media-worker.js');
      _jobs[id] = worker;

      void finish() {
        _jobs.remove(id)?.terminate();
      }

      void fail(Object message) {
        _rangeFallbacks.remove(id);
        emit('error', {'message': message});
        finish();
      }

      worker.onError.listen((_) {
        fail('媒体处理线程未能启动');
      });
      worker.onMessage.listen((event) {
        if (!_players.containsKey(id)) return;
        final result = event.data as Map;
        if (result['blob'] is html.Blob) {
          final url = html.Url.createObjectUrlFromBlob(
            result['blob'] as html.Blob,
          );
          _urls[id] = url;
          media.src = url;
          markCreated();
          finish();
        } else {
          fail(result['error'] ?? '媒体处理失败');
        }
      });
      worker.postMessage({
        'url': args['cdnUrl'],
        'key': key,
        'audioOnly': args['audioOnly'] == true,
      });
    } catch (_) {
      _jobs.remove(id)?.terminate();
      _rangeFallbacks.remove(id);
      emit('error', {'message': '媒体处理线程未能启动'});
    }
  }

  bool fallbackFromRange() {
    final range = _rangeUrls.remove(id);
    if (range == null || !_players.containsKey(id)) return false;
    _rangeStartupTimers.remove(id)?.cancel();
    _closeMediaRange(range.toJS);
    if (media.currentTime > 0) start = media.currentTime.toDouble();
    _rangeFallbacks.add(id);
    emit('buffering', true);
    startBlobWorker();
    return true;
  }

  media.onError.listen((_) {
    if (fallbackFromRange()) return;
    // The previous range source can still emit an error while Blob is downloading.
    if (_rangeFallbacks.contains(id) && !_urls.containsKey(id)) return;
    _rangeFallbacks.remove(id);
    emit('error', {'message': '浏览器无法播放该媒体', 'errorCode': media.error?.code});
  });

  if (key.isEmpty) {
    media.src = args['cdnUrl'] as String;
    markCreated();
  } else if (_rangeDriver != null && args['audioOnly'] != true) {
    unawaited(() async {
      try {
        final path = await _openMediaRange(
          (args['cdnUrl'] as String).toJS,
          key.toJS,
          (args['audioOnly'] == true).toJS,
        ).toDart;
        if (!_players.containsKey(id)) {
          _closeMediaRange(path);
          return;
        }
        final url = path.toDart;
        _rangeUrls[id] = url;
        _rangeStartupTimers[id] = Timer(
          const Duration(seconds: 8),
          fallbackFromRange,
        );
        media.src = url;
        markCreated();
      } catch (_) {
        startBlobWorker();
      }
    }());
  } else {
    startBlobWorker();
  }
  return {'playerId': id};
}
