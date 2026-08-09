# The published site

Docusaurus. `docs/STYLE.md` carries the rules and they are enforced by review.

## What must stay true

- **Licensed imagery must never reach docs.** No C-MAP chart, drawn or named.

- **The audience is a mariner, or a third-party plugin author arriving cold.**
  Second person, teaching, terms defined on first use, no internal debate and
  no reference to `specs/`, which is gitignored and dangles for every other
  reader.
- **Never publish real AIS or position data.** Live AIS carries other people's
  vessel names, MMSIs and positions. Frames come from the replay fixture, which
  `macos/screenshots.sh` serves itself.
