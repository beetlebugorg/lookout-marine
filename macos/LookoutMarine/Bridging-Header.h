//  Bridging-Header.h — exposes the lookout C ABI to Swift.
//
//  lookout.h transitively includes tile57.h (for tile57_mariner, tile57_query_cb
//  and the tile57_* enums). Both headers' directories must be on the target's
//  HEADER_SEARCH_PATHS (see macos/project.yml):
//    $(SRCROOT)/../include        — lookout.h
//    $(TILE57_DIR)/include        — tile57.h
#ifndef LOOKOUT_MARINE_BRIDGING_H
#define LOOKOUT_MARINE_BRIDGING_H

#include "lookout.h"

#endif /* LOOKOUT_MARINE_BRIDGING_H */
