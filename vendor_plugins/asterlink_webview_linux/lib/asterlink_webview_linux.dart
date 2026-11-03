import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

/// One browser window hosted by the native GTK/WebKitGTK side.
///
/// The window lives outside the Flutter widget tree (the Linux embedder has no
/// platform views), so everything this class exposes is a channel round trip.
class LinuxWebViewSession {
  LinuxWebViewSession({
    required this.id,
    required this.host,
  });

  final String id;
  final LinuxWebViewHost host;

  /// Events belonging to this window only.
  Stream<LinuxWebViewEvent> get events =>
      host.events.where((event) => event.id == id);

  Future<Uri?> currentUrl() async {
    final value = await host._invoke<String>('currentUrl', {'id': id});
    return value == null || value.isEmpty ? null : Uri.tryParse(value);
  }

  Future<String> title() async =>
      (await host._invoke<String>('title', {'id': id})) ?? '';

  /// Runs [script] in the page and returns its value.
  ///
  /// Strings come back as `String`, JSON-serialisable values as the decoded
  /// Dart object, `null`/`undefined` as `null`.
  Future<dynamic> evaluate(String script) async {
    final result = await host._invoke<Map<Object?, Object?>>('evaluate', {
      'id': id,
      'script': script,
    });
    if (result == null) return null;
    final value = result['value'];
    switch (result['kind']) {
      case 'string':
        return value;
      case 'json':
        if (value is String && value.isNotEmpty) {
          try {
            return jsonDecode(value);
          } catch (_) {
            return value;
          }
        }
        return value;
      default:
        return null;
    }
  }

  Future<void> loadUrl(String url) =>
      host._invoke<void>('loadUrl', {'id': id, 'url': url});

  Future<void> reload() => host._invoke<void>('reload', {'id': id});

  Future<void> stop() => host._invoke<void>('stop', {'id': id});

  Future<void> present() => host._invoke<void>('present', {'id': id});

  /// Answers a pending `navigation` event emitted by this window.
  Future<void> resolveNavigation(String token, {required bool allow}) =>
      host._invoke<void>('resolveNavigation', {
        'id': id,
        'token': token,
        'allow': allow,
      });

  /// Closes the native window. The `closed` event follows.
  Future<void> close() => host._invoke<void>('close', {'id': id});
}

class LinuxWebViewCookie {
  const LinuxWebViewCookie({
    required this.name,
    required this.value,
    this.domain = '',
    this.path = '/',
    this.secure = false,
    this.httpOnly = false,
  });

  final String name;
  final String value;
  final String domain;
  final String path;
  final bool secure;
  final bool httpOnly;

  factory LinuxWebViewCookie.fromMap(Map<Object?, Object?> map) =>
      LinuxWebViewCookie(
        name: (map['name'] ?? '') as String,
        value: (map['value'] ?? '') as String,
        domain: (map['domain'] ?? '') as String,
        path: (map['path'] ?? '/') as String,
        secure: map['secure'] == true,
        httpOnly: map['httpOnly'] == true,
      );
}

class LinuxWebViewEvent {
  const LinuxWebViewEvent({
    required this.type,
    required this.id,
    this.url,
    this.title,
    this.message,
    this.token,
    this.mainFrame = true,
    this.progress,
  });

  final String type;
  final String id;
  final String? url;
  final String? title;
  final String? message;
  final String? token;
  final bool mainFrame;
  final double? progress;

  static const loadStarted = 'loadStarted';
  static const loadFinished = 'loadFinished';
  static const loadFailed = 'loadFailed';
  static const urlChanged = 'urlChanged';
  static const titleChanged = 'titleChanged';
  static const progressChanged = 'progress';
  static const navigation = 'navigation';
  static const newWindow = 'newWindow';
  static const closed = 'closed';
  static const processTerminated = 'processTerminated';

  factory LinuxWebViewEvent.fromMap(Map<Object?, Object?> map) =>
      LinuxWebViewEvent(
        type: (map['type'] ?? '') as String,
        id: (map['id'] ?? '') as String,
        url: map['url'] as String?,
        title: map['title'] as String?,
        message: map['message'] as String?,
        token: map['token'] as String?,
        mainFrame: map['mainFrame'] != false,
        progress: (map['progress'] as num?)?.toDouble(),
      );
}

/// Entry point for the Linux web login browser.
class LinuxWebViewHost {
  LinuxWebViewHost._();

  static LinuxWebViewHost? _instance;

  static LinuxWebViewHost get instance => _instance ??= LinuxWebViewHost._();

  static const MethodChannel _methods = MethodChannel(
    'asterlink/webview_linux',
  );
  static const EventChannel _eventChannel = EventChannel(
    'asterlink/webview_linux/events',
  );

  final StreamController<LinuxWebViewEvent> _events =
      StreamController<LinuxWebViewEvent>.broadcast();
  StreamSubscription<dynamic>? _nativeEvents;
  int _sequence = 0;

  /// Every event from every window, already fused into one broadcast stream.
  Stream<LinuxWebViewEvent> get events {
    _listen();
    return _events.stream;
  }

  void _listen() {
    _nativeEvents ??= _eventChannel.receiveBroadcastStream().listen(
      (event) {
        if (event is! Map) return;
        _events.add(LinuxWebViewEvent.fromMap(event));
      },
      onError: (Object error) {
        // The channel only fails when the plugin is missing entirely; the
        // caller sees the failure on the first invoke instead.
      },
      cancelOnError: false,
    );
  }

  Future<T?> _invoke<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _methods.invokeMethod<T>(method, args);
    } on MissingPluginException {
      throw LinuxWebViewUnavailable(
        'Linux 网页登录组件未就绪（缺少 asterlink_webview_linux 插件）',
      );
    } on PlatformException catch (error) {
      throw LinuxWebViewUnavailable(error.message ?? 'Linux 网页登录窗口不可用');
    }
  }

  Future<LinuxWebViewSession> create({
    required String url,
    String? userAgent,
    bool ephemeral = false,
    String? title,
    int width = 1120,
    int height = 780,
    bool arbitrateNavigation = true,
    List<LinuxWebViewInitScript> initScripts = const [],
  }) async {
    final id = 'linux-login-${++_sequence}';
    _listen();
    final created = await _invoke<String>('create', {
      'id': id,
      'url': url,
      'userAgent': ?userAgent,
      'ephemeral': ephemeral,
      'title': ?title,
      'width': width,
      'height': height,
      'arbitrateNavigation': arbitrateNavigation,
      if (initScripts.isNotEmpty)
        'initScripts': [
          for (final script in initScripts)
            {
              'source': script.source,
              'injectionTime': script.atDocumentEnd
                  ? 'documentEnd'
                  : 'documentStart',
              'mainFrameOnly': script.mainFrameOnly,
            },
        ],
    });
    return LinuxWebViewSession(id: created ?? id, host: this);
  }

  /// Reads the shared login jar. Passing [session] scopes the manager to that
  /// window's profile (all login windows share one).
  Future<List<LinuxWebViewCookie>> cookies({String? session, String? url}) async {
    final list = await _invoke<List<Object?>>('getCookies', {
      'id': ?session,
      'url': ?url,
    });
    return [
      for (final entry in list ?? const <Object?>[])
        if (entry is Map) LinuxWebViewCookie.fromMap(entry),
    ];
  }

  Future<void> deleteAllCookies({String? session}) =>
      _invoke<void>('deleteAllCookies', {'id': ?session});

  Future<void> closeAll() => _invoke<void>('closeAll');

  Future<void> dispose() async {
    try {
      await _invoke<void>('dispose');
    } catch (_) {
      // Shutting down; nothing useful left to do with the failure.
    }
    await _nativeEvents?.cancel();
    _nativeEvents = null;
    await _events.close();
    _instance = null;
  }
}

class LinuxWebViewInitScript {
  const LinuxWebViewInitScript(
    this.source, {
    this.mainFrameOnly = true,
    this.atDocumentEnd = false,
  });

  final String source;
  final bool mainFrameOnly;
  final bool atDocumentEnd;
}

class LinuxWebViewUnavailable implements Exception {
  const LinuxWebViewUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}
