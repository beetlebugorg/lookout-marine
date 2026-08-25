# GSHHG coastline

`coastline.geojson` is a low-resolution extract of the Global Self-consistent, Hierarchical, High-resolution Geography Database (GSHHG). It holds 10,107 polygons: `level` 1 is the land/ocean boundary, `level` 2 is the lake/land boundary.

`tools/basemap.zig` bakes it into `basemap.pmtiles`, the vector tiles the core embeds.

## Source

GSHHG, by Paul Wessel (SOEST, University of Hawaii) and Walter H. F. Smith (NOAA Laboratory for Satellite Altimetry).

- <https://www.soest.hawaii.edu/pwessel/gshhg/>
- Wessel, P., and W. H. F. Smith, A Global Self-consistent, Hierarchical, High-resolution Shoreline Database, *J. Geophys. Res.*, 101(B4), 8741-8743, 1996.

This extract was copied from `web/basemap/` in [beetlebugorg/chartplotter](https://github.com/beetlebugorg/chartplotter), which renders the same data as its offline basemap.

## License

GSHHG is released under the GNU Lesser General Public License. The data are redistributed here unmodified. The rest of this repository is MIT; this directory is not.
