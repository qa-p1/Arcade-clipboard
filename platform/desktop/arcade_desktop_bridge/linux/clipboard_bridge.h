#ifndef ARCADE_CLIPBOARD_BRIDGE_H_
#define ARCADE_CLIPBOARD_BRIDGE_H_

#include <flutter_linux/flutter_linux.h>

// All operations complete on the GTK main loop. Payload reads are bounded and
// no selected content is written unless Flutter invokes writeClipboard.
bool HandleClipboardMethod(FlMethodCall* call);

#endif
