/* lk-discovery.h — what is already answering on the boat's network.
 *
 * A Signal K server announces itself over DNS-SD, and so do some NMEA
 * gateways. A connection list declares the service types it accepts
 * (lk-plugins.h), and this browses for them so the mariner can add a source
 * without typing an address.
 *
 * The browse goes through Avahi on the system bus rather than through
 * avahi-client, so the shell takes no dependency it did not already have:
 * GDBus comes with GLib, which GTK requires. A machine with no D-Bus, or none
 * running avahi-daemon, simply finds nothing.
 *
 * A FIND CARRIES THE HOST NAME, not the address behind it. A lease turns over
 * and the address changes; the name still reaches the same machine, and the
 * core resolves it again on every reconnect.
 */
#pragma once

#include <glib.h>

G_BEGIN_DECLS

/* One service on the network, resolved far enough to fill in a row. */
typedef struct {
  char *service; /* the type it answered for, which ties it to a list */
  char *name;    /* what the server calls itself; it becomes the row's name */
  char *host;    /* "boat.local" */
  int   port;
} LkDiscovered;

typedef struct _LkDiscovery LkDiscovery;

/* Called on the main loop whenever what has been found moves. */
typedef void (*LkDiscoveryChanged) (gpointer user_data);

/* Browses nothing until lk_discovery_browse. Never NULL: a machine without the
 * bus or the daemon answers an empty list for its whole life. */
LkDiscovery *lk_discovery_new (LkDiscoveryChanged changed, gpointer user_data);

/* Stops every browse and drops what was found. */
void lk_discovery_free (LkDiscovery *self);

G_DEFINE_AUTOPTR_CLEANUP_FUNC (LkDiscovery, lk_discovery_free)

/* Browse for exactly these service types (const char *) and no others.
 * Idempotent, so a caller may hand it the same list on every pass. */
void lk_discovery_browse (LkDiscovery *self, GPtrArray *services);

/* Everything resolved so far. Owned by the discovery and valid until the next
 * change callback. */
const GPtrArray *lk_discovery_found (LkDiscovery *self);

G_END_DECLS
