#ifndef FLUTTER_PLUGIN_ASTERLINK_WEBVIEW_LINUX_PLUGIN_H_
#define FLUTTER_PLUGIN_ASTERLINK_WEBVIEW_LINUX_PLUGIN_H_

#include <flutter_linux/flutter_linux.h>

G_BEGIN_DECLS

/**
 * asterlink_webview_linux_plugin_register_with_registrar:
 * @registrar: an #FlPluginRegistrar.
 *
 * Registers the Linux web login browser channels with the Flutter engine.
 */
void asterlink_webview_linux_plugin_register_with_registrar(
    FlPluginRegistrar* registrar);

G_END_DECLS

#endif  // FLUTTER_PLUGIN_ASTERLINK_WEBVIEW_LINUX_PLUGIN_H_
