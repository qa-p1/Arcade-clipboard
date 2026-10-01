#ifndef FLUTTER_PLUGIN_ARCADE_DESKTOP_BRIDGE_PLUGIN_H_
#define FLUTTER_PLUGIN_ARCADE_DESKTOP_BRIDGE_PLUGIN_H_

#include <flutter_plugin_registrar.h>

#ifdef FLUTTER_PLUGIN_IMPL
#define ARCADE_DESKTOP_EXPORT __declspec(dllexport)
#else
#define ARCADE_DESKTOP_EXPORT __declspec(dllimport)
#endif

#ifdef __cplusplus
extern "C" {
#endif

ARCADE_DESKTOP_EXPORT void ArcadeDesktopBridgePluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar);

#ifdef __cplusplus
}
#endif

#endif  // FLUTTER_PLUGIN_ARCADE_DESKTOP_BRIDGE_PLUGIN_H_
