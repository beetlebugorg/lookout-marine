/* library/agent.h — how this shell announces itself on the network.
 *
 * A unique, identifiable agent with a way to reach the developer. Public tile
 * hosts serve "access blocked" placeholder tiles to anonymous or
 * platform-default agents (openstreetmap.org's tile usage policy,
 * osm.wiki/Blocked_tiles), so every fetch this shell makes says who it is.
 *
 * ONE definition, shared by the fetcher the core drives and the shell's own
 * fetches: a publisher who allows one and blocks the other has been told two
 * different things by the same program.
 */
#pragma once

#define LK_USER_AGENT \
  "LookoutMarine/1.0 (Linux; org.beetlebug.lookout; contact jeremy.collins@beetlebug.org)"
#define LK_REFERER "https://beetlebug.org/"
