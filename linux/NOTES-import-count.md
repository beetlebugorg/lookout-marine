# The import count included prepared cells (T-013)

## What was wrong

`lk_scanned_cell_needs_prepare` reads the kind of one file. It returns TRUE for
an archived cell, for `LOOKOUT_FILE_SOURCE` and for
`LOOKOUT_FILE_RASTER_SOURCE`. An S-57 cell keeps the kind
`LOOKOUT_FILE_SOURCE` after the bake writes its chart, so the predicate stays
true for every source cell in a folder, import after import.

Two callers used that per-file predicate for a set-level count:

- `app-model.c`, the `to_prepare` count behind the import page.
- `bake.c`, the filter that built the band totals for the progress pill.

A mariner who downloads one region into a folder of charts saw the size of the
folder on the import page. Brief M-0030 reports one NOAA region priced at 932
charts and an import page that said 2630. A first install hides the fault,
because then every cell is new.

## What was already correct

`lk_chart_bake_start` skipped a chart it had already made. Further down the
same function it called `lookout_bake_output_path` for each item and dropped
the item when that file was on disk. The bake itself therefore did the right
work. The band totals were built before that skip ran, so the progress pill
overstated its totals as well.

## The fix

One set-level function, declared in `library/bake.h`:

```c
GPtrArray *lk_chart_bake_to_prepare (const char *source, const LkChartSet *set);
```

It keeps the cells that `lk_scanned_cell_needs_prepare` accepts, then drops
each cell whose prepared file is on disk. `lookout_bake_output_path` gives that
file name. The import page and the bake now use one rule, and the "already
made" test moved out of the bake loop into this function.

`lk_scanned_cell_needs_prepare` is unchanged. `lk_chart_set_picture_paths` and
the openable paths use it for the per-file question, and that answer is
correct.

Whether a cell needs preparing depends on the rest of the set, so the set
answers it once. That is the same split as the core at `src/chartsets.zig:503`
and the Apple shell at `274f3f7`.

### Why this shell uses the output path rule

The core and the Apple shell build a set of prepared stems and match a source
against it. Both can, because their prepared charts arrive in the same set as
the sources. This shell puts prepared charts under
`$XDG_DATA_HOME/lookout-marine/charts`, away from the folder the mariner
picked. `lookout_bake_output_path` is the contract for where a prepared chart
goes, so this shell calls it. Answer A-004 confirms this choice.

`g_file_test` asks for `G_FILE_TEST_IS_REGULAR`, because the bake also creates
a directory of the chart's name under the same root.

## Tests

`linux/tests/test-library.c`, two cases:

- `/library/prepared-cells-are-not-work`. A folder of cells, a BSB sheet and a
  picture. It prepares them a group at a time and counts what is left. It also
  asserts that `lk_scanned_cell_needs_prepare` still reads the kind alone.
- `/library/prepared-archive-is-not-work`. Every chart entry in an archive
  needs preparing, because each one has to be extracted. Each entry drops out
  of the count as its file appears. The test calls
  `lookout_bake_output_path` for each path, because a cell and a picture are
  prepared into different paths.

Both fail without the fix. The whole suite passes with it: 17 of 17, unit and
widget.

## A core bug found during the work

`rules.outputPath` in `src/shell/bake.zig` named a lift from `item.name`.
`library.cellName` returns the stem alone for a dataset name. A baked chart
lifted out of a .zip therefore came out as `<out>/US4TE3W0`, and
`lk_chart_paths_in_dir` globs `*.pmtiles`, so it never listed the chart again.
A lifted `.mbtiles` picture escaped the fault, because its stem is no dataset
name and its name keeps the extension.

The primary fixed it in `c95bac03`. This branch is rebased onto it, and the
suite above ran against it.

## Open item

This box has no ssh key and no agent, so `git push` to `git@github.com` fails.
Fetch works over anonymous HTTPS. Push works through the `gh` credential
helper, which reports the `beetlebugorg` account with `repo` scope.
