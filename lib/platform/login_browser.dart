import 'dart:async';
import 'dart:io' show Platform;

import 'package:asterlink_webview_linux/asterlink_webview_linux.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

export 'package:asterlink_webview_linux/asterlink_webview_linux.dart'
    show LinuxWebViewEvent, LinuxWebViewUnavailable;

/// Web login browsing differs per desktop platform:
///
/// * Windows / Android embed the web view in the Flutter tree through
///   `flutter_inappwebview`.
/// * Linux cannot: the Flutter Linux embedder has no platform views, so the
///   page is hosted in a native GTK window by `asterlink_webview_linux` and
///   driven over a channel.
///
/// The login flow only needs a handful of operations, so both back ends
/// implement the two small interfaces below and the pages stop caring.
abstract class LoginCookieJar {
  Future<List<LoginCookie>> getCookies({
    required Uri url,
    LoginBrowserPage? view,
  });

  Future<void> deleteAllCookies();
}

class LoginCookie {
  const LoginCookie(
    this.name,
    this.value, {
    this.domain,
    this.path,
    this.secure = false,
  });

  final String name;
  final String value;
  final String? domain;
  final String? path;
  final bool secure;

  @override
  String toString() => '$name=$value';
}

abstract class LoginBrowserPage {
  /// Stable key so the flow can tell two pages apart without knowing the type.
  String get identityKey;

  Future<Uri?> getUrl();

  Future<dynamic> evaluateJavascript({required String source});

  Future<void> reload();

  Future<void> loadUrl({required URLRequest urlRequest});

  Future<void> stopLoading();
}

bool? _detachedOverride;

/// True when the login page cannot be embedded and needs its own window.
bool get loginBrowserIsDetached => _detachedOverride ?? Platform.isLinux;

/// Lets widget tests keep exercising the embedded path on a Linux host, where
/// the native window cannot be created. Pass null to restore the default.
@visibleForTesting
void overrideLoginBrowserDetached(bool? detached) => _detachedOverride = detached;

/// Creates the cookie jar for the current platform.
///
/// Keeping this in one place means `CookieManager.instance()` is never
/// constructed on Linux, where it throws because the `flutter_inappwebview`
/// platform interface has no Linux implementation.
Future<LoginCookieJar> createLoginCookieJar(
  WebViewEnvironment? environment,
) async {
  if (loginBrowserIsDetached) return DetachedCookieJar();
  return EmbeddedCookieJar(
    CookieManager.instance(webViewEnvironment: environment),
  );
}

// ---------------------------------------------------------------------------
// Windows / Android
// ---------------------------------------------------------------------------

/// Wraps the `flutter_inappwebview` controller used on Windows and Android.
class EmbeddedLoginPage implements LoginBrowserPage {
  EmbeddedLoginPage(this.controller);

  final InAppWebViewController controller;

  @override
  String get identityKey => 'embedded-${identityHashCode(controller.platform)}';

  @override
  Future<Uri?> getUrl() async => controller.getUrl();

  @override
  Future<dynamic> evaluateJavascript({required String source}) =>
      controller.evaluateJavascript(source: source);

  @override
  Future<void> reload() => controller.reload();

  @override
  Future<void> loadUrl({required URLRequest urlRequest}) =>
      controller.loadUrl(urlRequest: urlRequest);

  @override
  Future<void> stopLoading() => controller.stopLoading();
}

class EmbeddedCookieJar implements LoginCookieJar {
  EmbeddedCookieJar(this.manager);

  final CookieManager manager;

  @override
  Future<List<LoginCookie>> getCookies({
    required Uri url,
    LoginBrowserPage? view,
  }) async {
    final controller = view is EmbeddedLoginPage ? view.controller : null;
    final entries = await manager.getCookies(
      url: WebUri(url.toString()),
      webViewController: controller,
    );
    return [
      for (final entry in entries)
        LoginCookie(
          entry.name,
          entry.value,
          domain: entry.domain,
          path: entry.path,
          secure: entry.isSecure == true,
        ),
    ];
  }

  @override
  Future<void> deleteAllCookies() => manager.deleteAllCookies();
}

// ---------------------------------------------------------------------------
// Linux
// ---------------------------------------------------------------------------

class DetachedLoginPage implements LoginBrowserPage {
  DetachedLoginPage(this.session);

  final LinuxWebViewSession session;

  /// Native events for this window.
  Stream<LinuxWebViewEvent> get events => session.events;

  Future<void> present() => session.present();

  Future<void> close() => session.close();

  Future<void> resolveNavigation(String token, {required bool allow}) =>
      session.resolveNavigation(token, allow: allow);

  @override
  String get identityKey => 'detached-${session.id}';

  @override
  Future<Uri?> getUrl() => session.currentUrl();

  @override
  Future<dynamic> evaluateJavascript({required String source}) =>
      session.evaluate(source);

  @override
  Future<void> reload() => session.reload();

  @override
  Future<void> loadUrl({required URLRequest urlRequest}) async {
    final url = urlRequest.url;
    if (url == null) return;
    await session.loadUrl(url.toString());
  }

  @override
  Future<void> stopLoading() => session.stop();
}

class DetachedCookieJar implements LoginCookieJar {
  @override
  Future<List<LoginCookie>> getCookies({
    required Uri url,
    LoginBrowserPage? view,
  }) async {
    final session = view is DetachedLoginPage ? view.session.id : null;
    final entries = await LinuxWebViewHost.instance.cookies(
      session: session,
      url: url.toString(),
    );
    return [
      for (final entry in entries)
        LoginCookie(
          entry.name,
          entry.value,
          domain: entry.domain.isEmpty ? null : entry.domain,
          path: entry.path,
          secure: entry.secure,
        ),
    ];
  }

  @override
  Future<void> deleteAllCookies() =>
      LinuxWebViewHost.instance.deleteAllCookies();
}

/// Opens a native GTK login window.
///
/// The caller drives it through the returned page and listens on
/// [DetachedLoginPage.events] for load/navigation/close events.
Future<DetachedLoginPage> openDetachedLoginPage({
  required String url,
  required String userAgent,
  String? title,
  bool arbitrateNavigation = true,
  List<UserScript> initScripts = const [],
}) async {
  final session = await LinuxWebViewHost.instance.create(
    url: url,
    userAgent: userAgent,
    title: title,
    arbitrateNavigation: arbitrateNavigation,
    initScripts: [
      for (final script in initScripts)
        LinuxWebViewInitScript(
          guardedScript(script),
          mainFrameOnly: script.forMainFrameOnly,
        ),
    ],
  );
  return DetachedLoginPage(session);
}

/// Rewrites a `UserScript` origin restriction into a host guard.
///
/// WebKitGTK cannot scope an injected script to a set of origins, so the script
/// is wrapped in an `if` that checks `location` first. Block scoping keeps
/// top-level `var`/`function` declarations reachable, matching the behaviour of
/// `allowedOriginRules` closely enough for the provider bootstraps.
String guardedScript(UserScript script) {
  final rules = script.allowedOriginRules;
  if (rules.isEmpty || rules.contains('*')) return script.source;
  final origins = <String>[];
  final hosts = <String>[];
  for (final rule in rules) {
    final uri = Uri.tryParse(rule);
    if (uri == null || uri.host.isEmpty) continue;
    origins.add('${uri.scheme}://${uri.host}');
    hosts.add(uri.host);
  }
  if (origins.isEmpty) return script.source;
  final allowed = origins.map((o) => "'$o'").join(',');
  final allowedHosts = hosts.map((h) => "'$h'").join(',');
  return 'if ([$allowed].indexOf(location.origin) >= 0 '
      '|| [$allowedHosts].indexOf(location.hostname) >= 0) {\n'
      '${script.source}\n}';
}
