#include "lk-discovery.h"

#include <gio/gio.h>
#include <string.h>

/* Avahi's own names for "any interface" and "any protocol". */
#define LK_AVAHI_IF_UNSPEC    (-1)
#define LK_AVAHI_PROTO_UNSPEC (-1)

#define LK_AVAHI_BUS    "org.freedesktop.Avahi"
#define LK_AVAHI_SERVER "org.freedesktop.Avahi.Server"
#define LK_AVAHI_BROWSER "org.freedesktop.Avahi.ServiceBrowser"

struct _LkDiscovery {
  GDBusConnection   *bus;      /* the system bus; NULL when there is none */
  GHashTable        *browsers; /* service type -> browser object path, or "" while asked for */
  GPtrArray         *found;    /* LkDiscovered* */
  GCancellable      *cancel;   /* everything in flight, cancelled on free */
  guint              item_new;
  guint              item_remove;
  LkDiscoveryChanged changed;
  gpointer           user_data;
  grefcount          refs;     /* the owner, plus one per call in flight */
};

/* One call in flight, so its answer knows which browse asked for it. The
 * discovery cancels every call it started when the owner frees it, but a reply
 * that already arrived is delivered with a result, not a cancellation, so the
 * callback could read a freed `self`. Each pending therefore holds a reference,
 * and the struct is finalised only when the last call is answered. */
typedef struct {
  LkDiscovery *self;
  char        *service;
} LkPending;

static LkDiscovery *lk_discovery_ref (LkDiscovery *self);
static void         lk_discovery_unref (LkDiscovery *self);

static void
lk_discovered_free (gpointer data)
{
  LkDiscovered *found = data;

  g_free (found->service);
  g_free (found->name);
  g_free (found->host);
  g_free (found);
}

/* A service type as this compares them: no trailing dot, whichever way the
 * manifest and the daemon each wrote it. */
static char *
lk_discovery_normalize (const char *type)
{
  gsize len = strlen (type);

  if (len > 0 && type[len - 1] == '.')
    return g_strndup (type, len - 1);
  return g_strdup (type);
}

static void
lk_discovery_moved (LkDiscovery *self)
{
  if (self->changed != NULL)
    self->changed (self->user_data);
}

/* ---- resolving ------------------------------------------------------------ */

static void
lk_pending_free (LkPending *pending)
{
  lk_discovery_unref (pending->self);
  g_free (pending->service);
  g_free (pending);
}

static void
lk_discovery_resolved (GObject *source, GAsyncResult *result, gpointer user_data)
{
  LkPending *resolve = user_data;
  g_autoptr (GError) error = NULL;
  g_autoptr (GVariant) reply =
    g_dbus_connection_call_finish (G_DBUS_CONNECTION (source), result, &error);

  if (reply == NULL)
    {
      /* A service that went away mid-resolve, or a daemon that is not there.
       * Both mean nothing to show, and neither is worth a line in the log. */
      lk_pending_free (resolve);
      return;
    }

  LkDiscovery *self = resolve->self;

  /* Nothing is browsing for this any more: the window shut while the resolve
   * was in flight. */
  if (!g_hash_table_contains (self->browsers, resolve->service))
    {
      lk_pending_free (resolve);
      return;
    }

  /* ResolveService answers interface, protocol, name, type, domain, host,
   * aprotocol, address, port, txt, flags. Taken by position: a signature
   * written out again here is one more thing to get wrong. */
  g_autoptr (GVariant) name_v = g_variant_get_child_value (reply, 2);
  g_autoptr (GVariant) host_v = g_variant_get_child_value (reply, 5);
  g_autoptr (GVariant) port_v = g_variant_get_child_value (reply, 8);
  const char *name = g_variant_get_string (name_v, NULL);
  const char *host = g_variant_get_string (host_v, NULL);
  guint16 port = g_variant_get_uint16 (port_v);

  if (port == 0 || host[0] == '\0')
    {
      lk_pending_free (resolve);
      return;
    }

  LkDiscovered *entry = g_new0 (LkDiscovered, 1);

  entry->service = g_strdup (resolve->service);
  entry->name = g_strdup (name);
  entry->host = lk_discovery_normalize (host); /* the daemon writes "boat.local" or "boat.local." */
  entry->port = port;

  /* One server answers on every interface it holds. The second answer is the
   * same machine, so it replaces the first rather than showing up beside it. */
  for (guint i = 0; i < self->found->len; i++)
    {
      const LkDiscovered *held = g_ptr_array_index (self->found, i);

      if (g_strcmp0 (held->service, entry->service) == 0 && g_strcmp0 (held->name, entry->name) == 0)
        {
          g_ptr_array_remove_index (self->found, i);
          break;
        }
    }
  g_ptr_array_add (self->found, entry);
  lk_pending_free (resolve);
  lk_discovery_moved (self);
}

/* ---- the browse ----------------------------------------------------------- */

static void
lk_discovery_item_new (GDBusConnection *bus,
                       const char      *sender,
                       const char      *path,
                       const char      *iface,
                       const char      *signal,
                       GVariant        *params,
                       gpointer         user_data)
{
  LkDiscovery *self = user_data;
  gint32 interface = 0, protocol = 0;
  const char *name = NULL, *type = NULL, *domain = NULL;
  guint32 flags = 0;

  g_variant_get (params, "(ii&s&s&su)", &interface, &protocol, &name, &type, &domain, &flags);

  g_autofree char *service = lk_discovery_normalize (type);

  /* Every browser this shell holds shares one subscription, so a signal for a
   * type nobody asked for is somebody else's. */
  if (!g_hash_table_contains (self->browsers, service))
    return;

  LkPending *resolve = g_new0 (LkPending, 1);

  resolve->self = lk_discovery_ref (self);
  resolve->service = g_steal_pointer (&service);

  /* Resolved on the interface and protocol it was seen on. A resolve that asks
   * for "any" can answer for an interface the service is not on. */
  g_dbus_connection_call (self->bus, LK_AVAHI_BUS, "/", LK_AVAHI_SERVER, "ResolveService",
                          g_variant_new ("(iisssiu)", interface, protocol, name, type, domain,
                                         LK_AVAHI_PROTO_UNSPEC, 0u),
                          NULL, G_DBUS_CALL_FLAGS_NONE, -1, self->cancel,
                          lk_discovery_resolved, resolve);
}

static void
lk_discovery_item_remove (GDBusConnection *bus,
                          const char      *sender,
                          const char      *path,
                          const char      *iface,
                          const char      *signal,
                          GVariant        *params,
                          gpointer         user_data)
{
  LkDiscovery *self = user_data;
  gint32 interface = 0, protocol = 0;
  const char *name = NULL, *type = NULL, *domain = NULL;
  guint32 flags = 0;

  g_variant_get (params, "(ii&s&s&su)", &interface, &protocol, &name, &type, &domain, &flags);

  g_autofree char *service = lk_discovery_normalize (type);

  for (guint i = 0; i < self->found->len; i++)
    {
      const LkDiscovered *held = g_ptr_array_index (self->found, i);

      if (g_strcmp0 (held->service, service) == 0 && g_strcmp0 (held->name, name) == 0)
        {
          g_ptr_array_remove_index (self->found, i);
          lk_discovery_moved (self);
          return;
        }
    }
}

static void
lk_discovery_browser_made (GObject *source, GAsyncResult *result, gpointer user_data)
{
  LkPending *pending = user_data;
  g_autoptr (GError) error = NULL;
  g_autoptr (GVariant) reply =
    g_dbus_connection_call_finish (G_DBUS_CONNECTION (source), result, &error);

  if (reply == NULL)
    {
      /* Cancelled with the window, no daemon on this machine, or a type Avahi
       * would not take. None of the three is worth a line in the log. */
      lk_pending_free (pending);
      return;
    }

  LkDiscovery *self = pending->self;

  /* Nothing asks for this type any more: the pane moved on while the daemon
   * was answering, and the browser it just made has already been let go. */
  if (!g_hash_table_contains (self->browsers, pending->service))
    {
      lk_pending_free (pending);
      return;
    }

  const char *path = NULL;

  g_variant_get (reply, "(&o)", &path);
  g_hash_table_insert (self->browsers, g_strdup (pending->service), g_strdup (path));
  lk_pending_free (pending);
}

static void
lk_discovery_free_browser (LkDiscovery *self, const char *path)
{
  if (path == NULL || path[0] == '\0')
    return;

  /* Fire and forget: the daemon frees the browser, and there is nothing to do
   * with the answer either way. */
  g_dbus_connection_call (self->bus, LK_AVAHI_BUS, path, LK_AVAHI_BROWSER, "Free", NULL, NULL,
                          G_DBUS_CALL_FLAGS_NONE, -1, NULL, NULL, NULL);
}

LkDiscovery *
lk_discovery_new (LkDiscoveryChanged changed, gpointer user_data)
{
  LkDiscovery *self = g_new0 (LkDiscovery, 1);
  g_autoptr (GError) error = NULL;

  g_ref_count_init (&self->refs);
  self->changed = changed;
  self->user_data = user_data;
  self->browsers = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, g_free);
  self->found = g_ptr_array_new_with_free_func (lk_discovered_free);
  self->cancel = g_cancellable_new ();
  self->bus = g_bus_get_sync (G_BUS_TYPE_SYSTEM, NULL, &error);

  if (self->bus == NULL)
    {
      g_debug ("discovery: no system bus (%s); nothing will be found",
               error != NULL ? error->message : "no reason given");
      return self;
    }
  /* ONE SUBSCRIPTION FOR EVERY BROWSER, matched on the service type each
   * signal carries. Subscribing per browser object would mean subscribing
   * after its path came back, and Avahi answers a browser it has already
   * announced the first services on. */
  self->item_new =
    g_dbus_connection_signal_subscribe (self->bus, LK_AVAHI_BUS, LK_AVAHI_BROWSER, "ItemNew", NULL,
                                        NULL, G_DBUS_SIGNAL_FLAGS_NONE, lk_discovery_item_new, self,
                                        NULL);
  self->item_remove =
    g_dbus_connection_signal_subscribe (self->bus, LK_AVAHI_BUS, LK_AVAHI_BROWSER, "ItemRemove",
                                        NULL, NULL, G_DBUS_SIGNAL_FLAGS_NONE,
                                        lk_discovery_item_remove, self, NULL);
  return self;
}

void
lk_discovery_browse (LkDiscovery *self, GPtrArray *services)
{
  if (self->bus == NULL)
    return;

  g_autoptr (GHashTable) want = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, NULL);

  for (guint i = 0; services != NULL && i < services->len; i++)
    g_hash_table_add (want, lk_discovery_normalize (g_ptr_array_index (services, i)));

  /* Anything no list asks for any more stops, and its finds go with it. */
  GHashTableIter iter;
  gpointer key, value;

  g_hash_table_iter_init (&iter, self->browsers);
  while (g_hash_table_iter_next (&iter, &key, &value))
    {
      if (g_hash_table_contains (want, key))
        continue;

      lk_discovery_free_browser (self, value);
      for (guint i = self->found->len; i > 0; i--)
        {
          const LkDiscovered *held = g_ptr_array_index (self->found, i - 1);

          if (g_strcmp0 (held->service, key) == 0)
            g_ptr_array_remove_index (self->found, i - 1);
        }
      g_hash_table_iter_remove (&iter);
    }

  g_hash_table_iter_init (&iter, want);
  while (g_hash_table_iter_next (&iter, &key, &value))
    {
      const char *service = key;

      if (g_hash_table_contains (self->browsers, service))
        continue;

      /* Held with no path yet: what ItemNew is matched against is the key, and
       * the path arrives when the daemon answers. */
      g_hash_table_insert (self->browsers, g_strdup (service), g_strdup (""));

      LkPending *pending = g_new0 (LkPending, 1);

      pending->self = lk_discovery_ref (self);
      pending->service = g_strdup (service);
      g_dbus_connection_call (self->bus, LK_AVAHI_BUS, "/", LK_AVAHI_SERVER, "ServiceBrowserNew",
                              g_variant_new ("(iissu)", LK_AVAHI_IF_UNSPEC, LK_AVAHI_PROTO_UNSPEC,
                                             service, "", 0u),
                              G_VARIANT_TYPE ("(o)"), G_DBUS_CALL_FLAGS_NONE, -1, self->cancel,
                              lk_discovery_browser_made, pending);
    }
}

const GPtrArray *
lk_discovery_found (LkDiscovery *self)
{
  return self->found;
}

static LkDiscovery *
lk_discovery_ref (LkDiscovery *self)
{
  g_ref_count_inc (&self->refs);
  return self;
}

static void
lk_discovery_finalize (LkDiscovery *self)
{
  if (self->bus != NULL)
    g_object_unref (self->bus);
  g_object_unref (self->cancel);
  g_hash_table_unref (self->browsers);
  g_ptr_array_unref (self->found);
  g_free (self);
}

static void
lk_discovery_unref (LkDiscovery *self)
{
  if (g_ref_count_dec (&self->refs))
    lk_discovery_finalize (self);
}

void
lk_discovery_free (LkDiscovery *self)
{
  if (self == NULL)
    return;

  /* The owner is done. Cut the notify and stop new work, so a call still in
     flight cannot report into the freed owner. The struct itself lives until
     the last call is answered: a reply that already arrived is delivered with a
     result, not a cancellation, so a callback must still find `self` valid. */
  self->changed = NULL;
  self->user_data = NULL;
  g_cancellable_cancel (self->cancel);

  if (self->bus != NULL)
    {
      GHashTableIter iter;
      gpointer key, value;

      g_hash_table_iter_init (&iter, self->browsers);
      while (g_hash_table_iter_next (&iter, &key, &value))
        lk_discovery_free_browser (self, value);

      if (self->item_new != 0)
        {
          g_dbus_connection_signal_unsubscribe (self->bus, self->item_new);
          self->item_new = 0;
        }
      if (self->item_remove != 0)
        {
          g_dbus_connection_signal_unsubscribe (self->bus, self->item_remove);
          self->item_remove = 0;
        }
    }

  lk_discovery_unref (self);
}
