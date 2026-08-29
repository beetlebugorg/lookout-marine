# Test fixtures

`plugins.json`, `tables.json` and `alerts-empty.json` are the core's own output,
captured with the shell's dev hook:

    macos/build.sh mac Debug
    LOOKOUT_MULTI=1 LOOKOUT_CLEAN=1 \
    LOOKOUT_OPEN="$PWD/android/app/src/main/assets/charts/US5MD1MC.pmtiles" \
    LOOKOUT_DUMP_JSON=macos/Tests/Fixtures \
      open -n macos/build-mac/Build/Products/Debug/LookoutMarine.app

Capture them again whenever the core changes what it sends. `LOOKOUT_CLEAN`
matters: without it the registry carries whatever connections this machine has
saved, which would put a developer's own instrument addresses in the repository.

`alerts.json` and `table-rows.json` are the worked examples in `include/lookout.h`
(`lookout_plugin_alerts_json` and `lookout_plugin_table_rows`), copied verbatim.
Nothing on this machine can raise a real AIS alarm without an instrument feed,
and the header's examples are the contract itself rather than a shape somebody
remembered.
