part of '../pages/audio_page.dart';

/// One paused player buffers the next chapter while the current one finishes.
class _AudioPreload {
  _AudioPreload(this.itemId, this.toneId, this.player);

  final String itemId;
  final String toneId;
  final NativePlayer player;
  AudioSource? source;
  late Future<bool> ready;
  bool prepared = false;
  bool cancelled = false;
  Future<void>? _disposal;

  Future<void> dispose() {
    cancelled = true;
    return _disposal ??= player.dispose().catchError((Object _) {});
  }
}

extension _AudioPlaybackPreload on _AudioPlaybackController {
  void _prefetchNextAudioChapter() {
    if (request.sourceLoader != null ||
        !_autoAdvance ||
        _index + 1 >= _chapters.length) {
      return;
    }
    final nextId = _chapters[_index + 1].itemId;
    final cacheKey = '$nextId|$_toneId';
    if (_audioSourceCache.containsKey(cacheKey)) return;
    unawaited(
      _loadSourceWithRetry(
        nextId,
      ).catchError((Object _) => AudioSource(itemId: nextId, url: '')),
    );
  }

  /// Fetches one chapter's audio source.
  ///
  /// The backend picks a pooled device per upstream request and the audio
  /// player host sometimes answers a body-level 403 for it, so the network
  /// path retries a few draws before the page reports a failure. An injected
  /// loader is exact and is never multiplied.
  ///
  /// A pure-TTS book has no default voice: the playinfo endpoint answers
  /// NO_THIS_TONE for tone 0, so the first selectable voice is retried once.
  Future<AudioSource> _loadSourceWithRetry(String itemId) {
    final key = '$_bookId|$itemId|$_toneId';
    return _audioSourceRequests.putIfAbsent(
      key,
      () => _loadAudioSource(itemId).whenComplete(() {
        _audioSourceRequests.remove(key);
      }),
    );
  }

  Future<AudioSource> _loadAudioSource(String itemId) async {
    final bookId = _bookId;
    final requestedTone = _toneId;
    // 已下载的章节直接命中本地文件：离线可播，在线也不重复拉流。本地命中
    // 排在注入 loader 之前，测试才能覆盖「离线优先」这条真实顺序。
    final local = await _localSource(itemId, requestedTone);
    if (local != null) return local;
    final loader = request.sourceLoader;
    if (loader != null) {
      return loader(
        itemId,
        toneId: requestedTone,
      ).timeout(const Duration(seconds: 30));
    }
    final cacheKey = '$itemId|$requestedTone';
    final cached = _audioSourceCache[cacheKey];
    if (cached != null) return cached;
    final toneId = requestedTone;
    AudioSource result;
    try {
      result = await _fetchSource(itemId, toneId, bookId: bookId);
    } on ApiException catch (error) {
      if (toneId != '0' ||
          !error.message.contains('NO_THIS_TONE') ||
          !_current(_generation)) {
        rethrow;
      }
      final fallback = _firstSelectableTone();
      if (fallback == null) rethrow;
      final tone = fallback;
      _toneSwitchedForChapter = true;
      result = await _fetchSource(itemId, tone, bookId: bookId);
    }
    _audioSourceCache[cacheKey] = result;
    while (_audioSourceCache.length > 5) {
      _audioSourceCache.remove(_audioSourceCache.keys.first);
    }
    return result;
  }

  void _prepareNextAudio() {
    final current = _player;
    if (_closed ||
        _loading ||
        _completed ||
        !_wantPlay ||
        !_autoAdvance ||
        _sleepAtChapterEnd ||
        _switchingVersion ||
        current == null ||
        !current.playing ||
        current.buffering ||
        _duration <= Duration.zero ||
        _index + 1 >= _chapters.length) {
      return;
    }
    final remaining =
        _duration -
        _position.value -
        Duration(seconds: _skipPoints.outroSeconds);
    if (remaining <= Duration.zero ||
        remaining.inMilliseconds > 30000 * _rate) {
      return;
    }
    final nextId = _chapters[_index + 1].itemId;
    if (_audioPreload?.itemId == nextId && _audioPreload?.toneId == _toneId) {
      return;
    }
    unawaited(_dropAudioPreload());
    final preload = _audioPreload = _AudioPreload(
      nextId,
      _toneId,
      request.playerFactory?.call() ?? NativePlayer(audioOnly: true),
    );
    preload.ready = () async {
      try {
        final source = await _loadSourceWithRetry(nextId);
        if (preload.cancelled) return false;
        final uri = Uri.tryParse(source.url);
        if (source.itemId != nextId ||
            uri == null ||
            !(uri.scheme == 'file' ||
                (const ['http', 'https'].contains(uri.scheme) &&
                    uri.host.isNotEmpty))) {
          throw const FormatException('Invalid audio source');
        }
        preload.source = source;
        // Native create prepares the media while playWhenReady stays false.
        await preload.player.create(source.url, source.keyHex);
        if (preload.cancelled || preload.player.lastError != null) {
          await preload.dispose();
          return false;
        }
        preload.prepared = true;
        return true;
      } catch (_) {
        await preload.dispose();
        return false;
      }
    }();
  }

  _AudioPreload? _takeAudioPreload(String itemId, String toneId) {
    final preload = _audioPreload;
    if (preload == null) return null;
    if (preload.cancelled || preload.player.lastError != null) {
      _audioSourceCache.remove('${preload.itemId}|${preload.toneId}');
    }
    if (preload.itemId != itemId ||
        preload.toneId != toneId ||
        !preload.prepared) {
      unawaited(_dropAudioPreload());
      return null;
    }
    _audioPreload = null;
    return preload;
  }

  Future<void> _dropAudioPreload() {
    final preload = _audioPreload;
    _audioPreload = null;
    return preload?.dispose() ?? Future<void>.value();
  }
}
