// The chart core's C ABI, as Swift sees it. lookout.h includes tile57.h, and
// `zig build` installs both into zig-out-$(PLATFORM_NAME)/include, which the
// target's header search path names.
#include "lookout.h"
