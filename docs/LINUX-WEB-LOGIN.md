# Linux 网页登录（WebKitGTK 窗口）

网盘登录在 Android / Windows 上是**内嵌**的：`flutter_inappwebview` 把 WebView 作为平台视图嵌进 Flutter 树里，
业务代码拿到 `InAppWebViewController` 直接读 Cookie、跑 JS。

Linux 没有这条路：

* Flutter 官方 Linux embedder **没有平台视图**（engine 的 PR #23985 / #24169 未合入），
  内嵌一个原生 GtkWidget 没有渲染载体；
* `flutter_inappwebview` 本身**没有 Linux 实现**（6.1.5 只依赖 android / ios / macos / web / windows），
  于是 `InAppWebViewPlatform.instance == null`，`CookieManager.instance()` 直接抛异常 ——
  这就是 Linux 上每个「网页登录」入口都报「网页登录组件初始化失败 / 验证页面不可用」的原因，与网盘厂商无关。

## 方案：独立 GTK 窗口 + 通道驱动

`vendor_plugins/asterlink_webview_linux` 是一个自写的最小插件（C++/GTK3 + WebKitGTK 4.1）：

| 项 | 实现 |
|---|---|
| 窗口 | 每个会话一个 `GtkWindow` + `WebKitWebView`，`transient_for` 主窗口 |
| 与 Dart 交互 | `MethodChannel asterlink/webview_linux`（命令）+ `EventChannel .../events`（事件） |
| Cookie | 每个插件实例一个 `WebKitWebContext`（持久化到 `$XDG_DATA_HOME/asterlink/webview`），所有窗口共用一个 jar；`incognito` 走 `webkit_web_context_new_ephemeral()` |
| 脚本注入 | `WebKitUserContentManager`，document-start |
| 导航裁决 | `decide-policy` 把决定权交给 Dart（等价于 `shouldOverrideUrlLoading`），8 秒未答复则放行 |
| 弹窗 | `create` 信号：同一 context 里再开一个窗口（cookie 共享，登录态能带回来） |

Dart 侧统一抽象在 `lib/platform/login_browser.dart`：

* `LoginBrowserPage` —— `getUrl / evaluateJavascript / reload / loadUrl / stopLoading`，两个实现：
  `EmbeddedLoginPage`（包 `InAppWebViewController`）与 `DetachedLoginPage`（包 Linux 会话）。
* `LoginCookieJar` —— `getCookies / deleteAllCookies`，两个实现同上。
* `loginBrowserIsDetached` —— 唯一的平台分支点，登录页据此决定「内嵌 webview」还是「独立窗口面板」。

登录页（`lib/ui/login_page.dart`、`quark_sms_verification_page.dart`、`ctfile_verification_page.dart`、
`guangya_verification_page.dart`）在 Linux 上显示一条「登录页面已在独立窗口中打开」的面板，
真正的页面在系统窗口里；加载完成、URL 变化、导航裁决、窗口关闭都由事件流驱动，走的还是同一套登录检测逻辑。

## 依赖

**编译期**（CI 的 `linux` job 已经装上，本机不需要）：

```
libwebkit2gtk-4.1-dev  libjavascriptcoregtk-4.1-dev
```

**运行期**（写进 deb 的 `Depends`，由 dpkg 安装）：

```
libwebkit2gtk-4.1-0  libjavascriptcoregtk-4.1-0  libsoup-3.0-0
```

对应 `tool/package_linux.py` 的 `SONAME_PACKAGES` 三个新条目。不打包、不编译 WebKit 本体。

实际在一台装好 deb 的 Deepin 25 上核对过，运行期所需全在，`dpkg -i` 之后**不需要再补装任何包**：

```
libwebkit2gtk-4.1-0  libjavascriptcoregtk-4.1-0  libsoup-3.0-0
bubblewrap  xdg-dbus-proxy        # WebKit 的 WebProcess 沙箱，已在系统里
```

helper 进程在 `/usr/lib/x86_64-linux-gnu/webkit2gtk-4.1/`（`WebKitWebProcess` 等），
不是 `/usr/libexec/…`。

## 插件状态不能挂在 registrar 上（2026-11-03 线上崩溃）

**现象**：dpkg 装好的包里点「网页登录」，页面停在「正在准备登录…」两三秒，整个程序消失，
终端里没有任何输出，`$?` 是 **139**（SIGSEGV，core 已转储）。

**根因**：`fl_plugin_registry_get_registrar_for_plugin()` **每次调用都新建**一个
`FlPluginRegistrar`，`generated_plugin_registrant.cc` 是用 `g_autoptr` 接的：

```c
g_autoptr(FlPluginRegistrar) asterlink_webview_linux_registrar =
    fl_plugin_registry_get_registrar_for_plugin(registry, "AsterlinkWebviewLinuxPlugin");
asterlink_webview_linux_plugin_register_with_registrar(asterlink_webview_linux_registrar);
// ← 这里 registrar 被 unref → finalize
```

所以把清理逻辑挂在 registrar 上（`g_object_set_data_full`）等于**注册函数一返回就执行**：
`g_plugin` 被置空、状态被 delete，而 method channel 还活着。Dart 侧第一个调用
（登录前清 cookie 的 `deleteAllCookies`）就走到 `CookieManagerForOrCreate` →
`g_plugin->context` 解引用空指针 → 平台线程 SIGSEGV → GTK 进程整体退出。

**现在的做法**（`asterlink_webview_linux_plugin.cc` 末尾有注释说明）：

* 状态是**进程级单例**，注册时 `g_plugin = plugin.release()`，不在 registrar 上挂任何析构；
* `OnMethodCall` / `OnListen` / `OnCancel` 开头判 `g_plugin == nullptr`，返回错误而不是崩；
* channel / event channel 的引用也由 messenger 持有，不主动 unref。

**没装 gdb / eu-stack 时怎么定位**：`core_pattern` 是 `core` 时，`ulimit -c unlimited`
跑一次就能在 cwd 拿到 core；用 `pyelftools` 读 `NT_PRSTATUS`（x86_64 寄存器阵列
从 offset `0x70` 开始，`rip` 是第 17 个）拿到崩溃地址，再按 `NT_FILE` 的映射表换算成
模块相对偏移，`objdump -d --start-address/--stop-address` 就能看到解引用的那一条指令。

## 已知限制

* **窗口是独立的**：不能和 Flutter 组件叠放。Linux 上登录页显示的是说明面板，不是网页。
* **弹窗**（`window.open` 的 SSO / 授权页）开成新的系统窗口，共用同一个 cookie jar；Dart 侧不再有
  `_windows` 栈，浏览器自己管理。
* **脚本无法按 origin 限定**：WebKitGTK 的 user script 没有 `allowedOriginRules`，`guardedScript()`
  把规则改写成 `location.origin / location.hostname` 判断包在脚本外面。顶层 `var` / `function`
  在块内仍然提升到全局（sloppy mode），与 `allowedOriginRules` 的效果基本一致。
* **百度手机号面板**（`baiduNativeLogin`）在 Linux 上关闭，直接走网页登录 —— 那个面板靠往隐藏页面注入
  脚本工作，独立窗口下体验会很怪，而官网页面本来就提供短信登录。
* **玲珑（.layer）层没有 WebKit**：`org.deepin.base/25.2.2` 不含 webkit，`collect_runtime_libs`
  会把 `libwebkit2gtk-4.1.so.0` 拷进去，但 `libexec/webkit2gtk-4.1/` 下的
  `WebKitWebProcess` / `WebKitNetworkProcess` 不是库，不会被带上，所以**层里的网页登录暂时不可用**。
  要支持得再把 helper 进程目录一起收进组合层，或让玲珑版明确只用手动登录。
* **在线预览 / 搜索安全验证**这两处仍需要内嵌浏览器，Linux 上改成提示文案（改为下载文件 / 换平台完成）。

## 插件目录布局（别改动）

```
vendor_plugins/asterlink_webview_linux/
├── pubspec.yaml            # pluginClass: AsterlinkWebviewLinuxPlugin
├── include/asterlink_webview_linux/*.h   # 公开头，注册入口
├── lib/asterlink_webview_linux.dart      # MethodChannel / EventChannel 客户端
└── linux/
    ├── CMakeLists.txt
    └── asterlink_webview_linux_plugin.cc # 实现必须在这里
```

`linux/CMakeLists.txt` 里的相对源文件路径是按 **CMakeLists.txt 所在目录** 解析的，
而 Flutter 生成的 `generated_plugins.cmake` 加的是 `<plugin>/linux` 这个子目录。
实现文件放在插件根目录就会在 CI 报 `Cannot find source file`（2026-11-03 实际踩过），
所以 `.cc` 固定放在 `linux/` 下，头文件通过 `${CMAKE_CURRENT_SOURCE_DIR}/../include` 引用。

## 本地编译自检（不装系统包、不需要 sudo）

CI 上跑一轮 `linux` job 要十几分钟，而这类错误（源文件路径、头文件签名、符号名）
本地就能提前抓出来。做法是把发行版的 `-dev` 包**解包到普通目录**当 sysroot 用，
不安装、不编译任何依赖：

```bash
mkdir -p ~/hdrcheck && cd ~/hdrcheck
apt-get download libwebkit2gtk-4.1-dev libjavascriptcoregtk-4.1-dev libgtk-3-dev libgio-2.0-dev
mkdir -p root && for d in *.deb; do dpkg-deb -x "$d" root; done

R=~/hdrcheck/root/usr
g++ -fsyntax-only -std=c++17 -Wall \
  -I$R/include/gtk-3.0 -I$R/include/glib-2.0 -I$R/lib/x86_64-linux-gnu/glib-2.0/include \
  -I$R/include/pango-1.0 -I$R/include/harfbuzz -I$R/include/cairo \
  -I$R/include/gdk-pixbuf-2.0 -I$R/include/atk-1.0 -I$R/include/fribidi \
  -I$R/include/webkitgtk-4.1 -I$R/include/libsoup-3.0 -I$R/include/epoxy \
  -Ivendor_plugins/asterlink_webview_linux/include -Ilinux/flutter/ephemeral \
  vendor_plugins/asterlink_webview_linux/linux/asterlink_webview_linux_plugin.cc
```

`-fsyntax-only` 只查头文件与函数签名；再想验证链接，可以编成 `.o` 后
`nm -u` 对照 `libwebkit2gtk-4.1.so.0` / `libjavascriptcoregtk-4.1.so.0` /
`libsoup-3.0.so.0` 的导出符号，确认没有写错名字。
真正走一遍 CMake（含 `pkg_check_modules` 与相对路径解析）的话，造一个只 `add_subdirectory`
插件目录、并伪造 `flutter` imported target 的小工程即可（见 2026-11-03 的验证记录）。

## 手动验证（在桌面会话里跑）

```bash
# 1) 引擎可用性（不装本项目的任何东西）
/usr/lib/x86_64-linux-gnu/webkit2gtk-4.1/MiniBrowser https://pan.quark.cn

# 2) 应用内：网盘管理 → 添加账号 → 网页登录
#    应弹出独立窗口；在窗口里完成登录，回来点「检测登录」
```

如果窗口打不开而 `MiniBrowser` 正常，先看 `journalctl --user -f` 或终端里的
`asterlink_webview_linux:` 前缀告警。
