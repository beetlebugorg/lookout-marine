/* library/fetch.h — the url fetcher lookout drives.
 *
 * lookout does no networking. It asks the shell for a url and the shell
 * answers, which is how a publisher's style, its TileJSON, its sprite packs
 * and every one of its tiles arrive. See include/lookout.h,
 * lookout_set_http_provider.
 *
 * ONE fetcher per lookout handle. The shell opens a second handle to draw a
 * picture of a style nobody has picked, and that handle needs a fetcher of its
 * own: request ids are per handle, and an answer carried to the wrong one
 * lands on whatever request happens to hold that number.
 *
 * Everything here runs on the main thread. The render tick is the main thread,
 * so lookout's asks arrive there and soup answers there.
 */
#pragma once

#include <glib.h>
#include <lookout.h>

G_BEGIN_DECLS

typedef struct _LkFetcher LkFetcher;

/* How an answer reaches the handle that asked. The caller owns that decision:
 * a windowed handle answers through its controller, which also asks for the
 * frame that adopts the answer, and an offscreen handle answers straight
 * through lookout_http_respond. */
typedef void (*LkFetcherRespond) (gpointer user_data, uint64_t req_id,
                                  const void *bytes, gsize len, int status);

LkFetcher *lk_fetcher_new (LkFetcherRespond respond, gpointer user_data);
void       lk_fetcher_free (LkFetcher *self);

/* Pass these to whichever installer the caller has:
 * lk_chart_controller_set_http_provider, or lookout_set_http_provider. `user`
 * is the LkFetcher. */
void lk_fetcher_http_get (void *user, uint64_t req_id, const char *url, int allow_file);
void lk_fetcher_http_cancel (void *user, uint64_t req_id);

/* Whether asks are answered at all. A fetcher that is not live answers every
 * ask with a failure, which is what keeps lookout's request slots free while
 * a handle is being replaced. */
void lk_fetcher_set_live (LkFetcher *self, gboolean live);

/* Cancel every fetch in flight. Call this before the handle that asked for
 * them is replaced: a new handle reuses the old one's request ids. */
void lk_fetcher_cancel_all (LkFetcher *self);

G_END_DECLS
