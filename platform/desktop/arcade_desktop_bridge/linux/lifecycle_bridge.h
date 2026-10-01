#ifndef ARCADE_LIFECYCLE_BRIDGE_H_
#define ARCADE_LIFECYCLE_BRIDGE_H_

#include <flutter_linux/flutter_linux.h>

struct LinuxLifecycle;
LinuxLifecycle* CreateLinuxLifecycle(FlPluginRegistrar* registrar, FlMethodChannel* channel);
bool HandleLifecycleMethod(LinuxLifecycle* lifecycle, FlMethodCall* call);
void DestroyLinuxLifecycle(LinuxLifecycle* lifecycle);

#endif
