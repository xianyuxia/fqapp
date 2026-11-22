import 'dart:async';
import 'dart:html' as html;
import 'package:flutter/services.dart';

final browserSpeechEvents = StreamController<dynamic>.broadcast();
final _utterances = <String, html.SpeechSynthesisUtterance>{};
String? _voice;
double _rate = 1;

dynamic browserSpeech(String method, dynamic args) {
  final engine = html.window.speechSynthesis;
  if (engine == null) throw MissingPluginException('此浏览器不支持系统朗读');
  void clear() {
    _utterances.clear();
    engine.cancel();
  }

  switch (method) {
    case 'engines':
      return {
        'defaultEngine': 'default',
        'engines': [
          {'package': 'default', 'label': '系统默认语音'},
          for (final voice in engine.getVoices())
            {
              'package': voice.voiceUri,
              'label': '${voice.name} (${voice.lang})',
            },
        ],
      };
    case 'initialize':
      clear();
      _voice = args['engine'] as String?;
      _rate = ((args['rate'] as num?) ?? 1).toDouble().clamp(0.1, 10);
      return 300;
    case 'speak':
      if (args['queue'] != true) clear();
      final id = args['id'] as String;
      final utterance = html.SpeechSynthesisUtterance(args['text'] as String)
        ..lang = 'zh-CN'
        ..rate = _rate;
      for (final voice in engine.getVoices()) {
        if (voice.voiceUri == _voice) {
          utterance.voice = voice;
          break;
        }
      }
      _utterances[id] = utterance;
      void notify(String type, [int? start]) {
        if (!identical(_utterances[id], utterance)) return;
        if (type == 'done' || type == 'error') _utterances.remove(id);
        browserSpeechEvents.add({
          'id': id,
          'type': type,
          if (start != null) 'start': start,
        });
      }
      utterance.onStart.listen((_) => notify('start'));
      utterance.onEnd.listen((_) => notify('done'));
      utterance.addEventListener('error', (_) => notify('error'));
      utterance.onBoundary.listen((e) => notify('range', e.charIndex));
      engine.speak(utterance);
      return null;
    case 'stop':
    case 'pause':
    case 'shutdown':
      clear();
      return null;
    default:
      throw MissingPluginException('浏览器不支持此朗读指令');
  }
}
