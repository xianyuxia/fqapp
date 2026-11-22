import 'dart:js_interop';

import 'secure_key_storage.dart';

@JS('shijinpuStorage')
external JSPromise<JSString?> _storage(
  JSString key,
  JSString action,
  JSString? value,
);

SecureKeyStorage defaultSecureKeyStorage() => const _BrowserKeyStorage();

class _BrowserKeyStorage implements SecureKeyStorage {
  const _BrowserKeyStorage();

  @override
  Future<String?> read(String key) async =>
      (await _storage(key.toJS, 'read'.toJS, null).toDart)?.toDart;

  @override
  Future<void> write(String key, String value) async {
    await _storage(key.toJS, 'write'.toJS, value.toJS).toDart;
  }

  @override
  Future<void> delete(String key) async {
    await _storage(key.toJS, 'delete'.toJS, null).toDart;
  }
}
