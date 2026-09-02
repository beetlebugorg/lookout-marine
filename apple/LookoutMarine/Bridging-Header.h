//  Bridging-Header.h — exposes the lookout C ABI to Swift.
//
//  lookout.h includes lookout-library.h, lookout-plugins.h and lookout-shell.h,
//  and tile57.h (for tile57_mariner, tile57_query_cb and the tile57_* enums).
//  `zig build` installs all five into zig-out*/include, which is the target's
//  one HEADER_SEARCH_PATHS entry (see apple/project.yml).
#ifndef LOOKOUT_MARINE_BRIDGING_H
#define LOOKOUT_MARINE_BRIDGING_H

#include "lookout.h"

#endif /* LOOKOUT_MARINE_BRIDGING_H */
