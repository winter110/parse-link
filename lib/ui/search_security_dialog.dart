import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../app_services.dart';
import '../core/json.dart';
import '../data/resource_search_api.dart';
import '../data/search_security.dart';
import '../platform/login_browser.dart';
import 'common.dart';
import 'login_webview.dart';

/// Lives above the tab shell so preview requests can verify on any route.
class SearchSecurityHost extends StatefulWidget {
  const SearchSecurityHost(this.services, {super.key, required this.child});
  final AppServices services;
  final Widget child;
  @override
  State<SearchSecurityHost> createState() => _SearchSecurityHostState();
}

class _SearchSecurityHostState extends State<SearchSecurityHost> {
  SearchSecurityClient? _client;
  late final _handler = _verify;
  @override
  void initState() {
    super.initState();
    _attach();
  }

  void _attach() {
    final api = widget.services.resourceSearch.api;
    if (api is HttpResourceSearchApi) {
      _client = api.security;
      _client!.onVerification = _handler;
    }
  }

  @override
  void didUpdateWidget(SearchSecurityHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.services != widget.services) {
      _detach();
      _attach();
    }
  }

  void _detach() {
    if (_client?.onVerification == _handler) _client?.onVerification = null;
  }

  Future<bool> _verify(
    SearchSecurityClient client,
    CancelToken cancellation,
  ) async {
    if (!mounted || cancellation.isCancelled) return false;
    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (_) =>
              SearchSecurityDialog(widget.services, client, cancellation),
        ) ??
        false;
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class SearchSecurityDialog extends StatefulWidget {
  const SearchSecurityDialog(
    this.services,
    this.client,
    this.cancellation, {
    super.key,
  });
  final AppServices services;
  final SearchSecurityClient client;
  final CancelToken cancellation;
  @override
  State<SearchSecurityDialog> createState() => _SearchSecurityDialogState();
}

class _SearchSecurityDialogState extends State<SearchSecurityDialog> {
  final _images = <String, Uint8List>{};
  Json? _challenge;
  final _selected = <int>[];
  bool _loading = true, _sending = false, _consumed = false;
  String _message = '';
  @override
  void initState() {
    super.initState();
    _load();
    unawaited(
      widget.cancellation.whenCancel.then((_) {
        if (mounted) Navigator.of(context).removeRoute(ModalRoute.of(context)!);
      }),
    );
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _challenge = null;
      _selected.clear();
      _images.clear();
      _message = '';
      _consumed = false;
    });
    try {
      final challenge = await widget.client.challenge();
      if (mounted) setState(() => _challenge = challenge);
    } catch (error) {
      if (mounted) {
        setState(
          () =>
              _message = error is AppException ? error.message : '验证码加载失败，请重试',
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _submit([Json? credentials]) async {
    final challenge = _challenge;
    if (challenge == null || _sending || _consumed) return;
    setState(() {
      _sending = true;
      _message = '';
    });
    try {
      await widget.client.verify(
        challenge,
        credentials ?? {'answer': List<int>.of(_selected)},
      );
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) {
        setState(() {
          _consumed = true;
          _message = error is AppException ? error.message : '验证服务暂时不可用，请换一张重试';
        });
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _tencent() async {
    final answer = await Navigator.of(context).push<Json>(
      MaterialPageRoute(
        builder: (_) =>
            _TencentVerificationPage(widget.services, widget.client.endpoint),
      ),
    );
    if (mounted && answer != null) await _submit(answer);
  }

  Widget _image(String value) {
    try {
      require(value.startsWith('data:image/png;base64,'), '验证码图片无效');
      return Image.memory(
        _images.putIfAbsent(
          value,
          () => base64Decode(value.substring(value.indexOf(',') + 1)),
        ),
        fit: BoxFit.fill,
        gaplessPlayback: false,
        errorBuilder: (_, _, _) => const Center(child: Text('图片加载失败，请换一张')),
      );
    } catch (_) {
      return const Center(child: Text('图片加载失败，请换一张'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context), colors = theme.colorScheme;
    final challenge = _challenge,
        tencent = challenge?.str('provider') == 'tencent';
    return Dialog(
      insetPadding: const EdgeInsets.all(20),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 390),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.verified_user_outlined, color: colors.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text('安全验证', style: theme.textTheme.titleLarge),
                  ),
                  IconButton(
                    tooltip: '取消验证',
                    onPressed: () => Navigator.pop(context, false),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                tencent ? '请完成验证，随后自动继续本次操作。' : '按从左到右的顺序，点选下图中的三个字符。',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                  height: 1.6,
                ),
              ),
              const SizedBox(height: 16),
              if (_loading)
                const SizedBox(
                  height: 220,
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (challenge != null && !tencent) ...[
                Center(
                  child: SizedBox(
                    width: 144,
                    height: 48,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: _image(challenge.str('prompt_image')),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: AspectRatio(
                    aspectRatio: 4 / 3,
                    child: Stack(
                      children: [
                        Positioned.fill(child: _image(challenge.str('image'))),
                        Positioned.fill(
                          child: GridView.builder(
                            padding: EdgeInsets.zero,
                            physics: const NeverScrollableScrollPhysics(),
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 4,
                                ),
                            itemCount: 12,
                            itemBuilder: (_, index) {
                              final order = _selected.indexOf(index);
                              return Semantics(
                                button: true,
                                label: '第 ${index + 1} 格',
                                selected: order >= 0,
                                child: Material(
                                  color: Colors.transparent,
                                  child: InkWell(
                                    key: ValueKey('search-captcha-cell-$index'),
                                    onTap: _sending || _consumed
                                        ? null
                                        : () => setState(() {
                                            if (order >= 0) {
                                              _selected.removeRange(
                                                order,
                                                _selected.length,
                                              );
                                            } else if (_selected.length < 3) {
                                              _selected.add(index);
                                            }
                                          }),
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: order >= 0
                                            ? colors.primary.withValues(
                                                alpha: .12,
                                              )
                                            : null,
                                        border: Border.all(
                                          color: order >= 0
                                              ? colors.primary
                                              : Colors.black12,
                                          width: order >= 0 ? 2 : .4,
                                        ),
                                      ),
                                      alignment: Alignment.topLeft,
                                      padding: const EdgeInsets.all(5),
                                      child: order < 0
                                          ? null
                                          : CircleAvatar(
                                              radius: 11,
                                              backgroundColor: colors.primary,
                                              child: Text(
                                                '${order + 1}',
                                                style: TextStyle(
                                                  color: colors.onPrimary,
                                                  fontSize: 12,
                                                ),
                                              ),
                                            ),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ] else if (tencent)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 30),
                  child: FilledButton.icon(
                    onPressed: _sending || _consumed ? null : _tencent,
                    icon: const Icon(Icons.shield_outlined),
                    label: const Text('打开腾讯云验证'),
                  ),
                ),
              const SizedBox(height: 12),
              Text(
                _message.isNotEmpty
                    ? _message
                    : _sending
                    ? '正在验证…'
                    : '有效期 2 分钟 · 已点选 ${_selected.length}/3',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: _message.isNotEmpty
                      ? colors.error
                      : colors.onSurfaceVariant,
                ),
                semanticsLabel: _message,
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  OutlinedButton(
                    onPressed: _loading || _sending ? null : _load,
                    child: const Text('换一张'),
                  ),
                  const SizedBox(width: 12),
                  if (!tencent)
                    Expanded(
                      child: FilledButton(
                        onPressed:
                            !_loading &&
                                !_sending &&
                                !_consumed &&
                                _selected.length == 3
                            ? _submit
                            : null,
                        child: Text(_sending ? '正在验证' : '确认验证'),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                '验证通过后自动继续，有效期内无需重复验证。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TencentVerificationPage extends StatefulWidget {
  const _TencentVerificationPage(this.services, this.endpoint);
  final AppServices services;
  final String endpoint;
  @override
  State<_TencentVerificationPage> createState() =>
      _TencentVerificationPageState();
}

class _TencentVerificationPageState extends State<_TencentVerificationPage> {
  WebViewEnvironment? _environment;
  bool _ready = false, _finished = false;
  String _error = '';
  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      _environment = await widget.services.webEnvironment();
      if (mounted) setState(() => _ready = true);
    } catch (_) {
      if (mounted) setState(() => _error = '验证组件启动失败，请返回重试');
    }
  }

  @override
  Widget build(BuildContext context) => PageFrame(
    title: '安全验证',
    child: _error.isNotEmpty
        ? Center(child: Text(_error))
        : !_ready
        ? const Center(child: CircularProgressIndicator())
        : loginBrowserIsDetached
        ? const Center(child: Text('安全验证需要内嵌浏览器，请在 Windows 或 Android 版完成'))
        : InAppWebView(
            webViewEnvironment: _environment,
            initialUrlRequest: URLRequest(
              url: WebUri('${widget.endpoint}/security/verify?client=app'),
            ),
            initialSettings: webSettings(),
            onWebViewCreated: (web) {
              web.addJavaScriptHandler(
                handlerName: 'searchCaptcha',
                callback: (args) async {
                  final current = (await web.getUrl())?.uriValue;
                  final expected = Uri.parse(widget.endpoint);
                  if (!mounted ||
                      _finished ||
                      current == null ||
                      current.origin != expected.origin ||
                      current.path != '/security/verify' ||
                      args.length != 1) {
                    return null;
                  }
                  final value = asJson(args.first);
                  if (value.str('ticket').isEmpty ||
                      value.str('randstr').isEmpty) {
                    return null;
                  }
                  _finished = true;
                  if (context.mounted) Navigator.pop(context, value);
                  return null;
                },
              );
            },
            shouldOverrideUrlLoading: (_, action) async {
              if (!action.isForMainFrame) return NavigationActionPolicy.ALLOW;
              final target = action.request.url?.uriValue;
              return target != null &&
                      target.origin == Uri.parse(widget.endpoint).origin &&
                      target.path == '/security/verify'
                  ? NavigationActionPolicy.ALLOW
                  : NavigationActionPolicy.CANCEL;
            },
            onReceivedError: (_, request, _) {
              if (mounted && request.isForMainFrame == true) {
                setState(() => _error = '验证页面加载失败，请返回重试');
              }
            },
          ),
  );
}
