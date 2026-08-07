import React from 'react';
import Link from '@docusaurus/Link';

/**
 * The landing page's three blocks. Layout is option 1a; the hero is option 1b's
 * depth ladder rather than 1a's screenshot, so the front page costs no image
 * weight and the ground the wordmark sits on is the S-52 depth ramp itself.
 *
 * Every colour here comes from a token. The bands are --chart-* (verbatim from
 * the chart engine's tables), everything else is --chrome-* or a semantic alias,
 * so the page follows the reader's light/dark choice the way the app's chrome
 * follows the chart.
 */

/* Deep to dry. The percentages are the ramp's proportions from the mockup, not
   depths — the band heights are a picture of the ladder, not a chart. */
const BANDS = [
  {token: 'var(--chart-depdw)', height: '34%'},
  {token: 'var(--chart-depmd)', height: '16%'},
  {token: 'var(--chart-depms)', height: '14%'},
  {token: 'var(--chart-depvs)', height: '12%'},
  {token: 'var(--chart-depit)', height: '6%'},
  {token: 'var(--chart-landa)', height: 'auto', grow: true},
];

/* Soundings in FEET, whole numbers — a foot sounding is never fractional. Each
   one is plausible for the band it sits in and they shoal band by band toward
   the land, so the ladder reads as a survey and not as decoration.
   Colour is the S-52 rule: SNDG1 (grey) for water deeper than the safety
   contour, SNDG2 (black) for everything inshore of it. The contour is at 34%,
   so `top` alone decides which side a sounding is on.
   Positions avoid the info panel, which covers the left of the ramp. */
const SAFETY_CONTOUR_PCT = 34;

const SOUNDINGS = [
  /* DEPDW — deep water, outside the safety contour. Shoaling toward it. */
  {v: '48', left: '9%', top: '7%'},
  {v: '39', left: '26%', top: '9%'},
  {v: '55', left: '71%', top: '9%'},
  {v: '42', left: '60%', top: '22%'},
  {v: '31', left: '88%', top: '27%'},
  /* DEPMD — just inshore of the safety contour. */
  {v: '24', left: '79%', top: '40%'},
  {v: '21', left: '62%', top: '46%'},
  /* DEPMS */
  {v: '16', left: '93%', top: '56%'},
  {v: '14', left: '70%', top: '60%'},
  /* DEPVS */
  {v: '9', left: '85%', top: '69%'},
  {v: '7', left: '60%', top: '72%'},
  /* DEPIT — drying heights on the intertidal band. */
  {v: '2', left: '91%', top: '79%'},
  {v: '1', left: '14%', top: '79%'},
];

/* The ramp's own names, each paired with what it means, so the legend reads
   without an S-52 table to hand. Each is pinned to the thing it names — the
   band it labels, or the contour line it sits on — rather than distributed down
   the edge, which left them stranded mid-band. */
const LADDER_LEGEND = [
  {label: 'Depdw · deep water', top: '4%'},
  {label: 'Safety contour', top: '34%'},
  {label: 'Depit · intertidal', top: '77.5%'},
  {label: 'Landa · dry land', top: '90%'},
];

export function DepthLadderHero() {
  return (
    <section className="lm-hero">
      <div className="lm-hero__bands" aria-hidden="true">
        {BANDS.map((b, i) => (
          <div
            key={i}
            className="lm-hero__band"
            style={{
              background: b.token,
              flex: b.grow ? '1' : `0 0 ${b.height}`,
            }}
          />
        ))}
      </div>

      {/* The two contours the ramp implies: the deep contour and the safety
          contour. Drawn only across the open water to the right of the copy. */}
      <span className="lm-hero__contour" style={{top: '34%'}} aria-hidden="true" />
      <span className="lm-hero__contour" style={{top: '62%'}} aria-hidden="true" />

      {SOUNDINGS.map((s) => (
        <span
          key={s.v + s.left}
          className="lm-hero__sounding lm-num"
          style={{
            left: s.left,
            top: s.top,
            color:
              parseFloat(s.top) < SAFETY_CONTOUR_PCT
                ? 'var(--chart-sndg1)'
                : 'var(--chart-sndg2)',
          }}
          aria-hidden="true">
          {s.v}
        </span>
      ))}

      {LADDER_LEGEND.map((l) => (
        <span key={l.label} className="lm-hero__legendItem" style={{top: l.top}} aria-hidden="true">
          {l.label}
        </span>
      ))}

      {/* A chart states its unit. So does this one. */}
      <span className="lm-hero__unit" aria-hidden="true">
        Soundings in feet
      </span>

      {/* Option 1a's info box, floated on option 1b's ladder. It is opaque, so
          no band edge ever cuts through a line of type — the panel is the
          reason the copy reads at all against a six-colour ground. */}
      <div className="lm-hero__panel">
        <h1 className="lm-hero__title">
          The chart is
          <br />
          the interface.
        </h1>
        <p className="lm-hero__lede">
          Official ENC charts drawn with the IHO portrayal rules, straight to the
          GPU. Built for speed: pan, zoom and rotate a whole coastline without
          dropping a frame.
        </p>
        <div className="lm-caution">
          <span className="lm-caution__dot" />
          <span className="lm-caution__term">Not for navigation</span>
          <span className="lm-caution__body">
            A prototype. It makes no claim of ECDIS conformance.
          </span>
        </div>
        <div className="lm-hero__actions">
          <Link className="lm-btn lm-btn--primary" to="/user-guide/getting-started">
            Getting started
          </Link>
          <Link className="lm-btn" to="/developer-guide/architecture">
            Build from source
          </Link>
        </div>
      </div>
    </section>
  );
}

/**
 * 1a's proof strip. The shots are passed in rather than imported here so the
 * page keeps one place where an image path is written down.
 *
 * `shots` are the desktop hosts, which share one landscape aspect and so can be
 * cropped to a common grid. `devices` are the framed handhelds — they keep
 * their own proportions, because a framed device cropped to a landscape box
 * stops looking like the device.
 */
export function PlatformStrip({shots = [], devices = []}) {
  return (
    <section className="lm-strip">
      <div className="lm-strip__head">
        <h2 className="lm-strip__title">One design, six platforms</h2>
        <span className="lm-strip__note">
          The same chart, drawn by the same engine, whichever machine you are at.
        </span>
      </div>
      <div className="lm-strip__grid">
        {shots.map((s) => (
          <figure key={s.name} className="lm-shot">
            <img src={s.src} alt={s.alt} loading="lazy" />
            <figcaption>
              <b>{s.name}</b> · {s.toolkit}
            </figcaption>
          </figure>
        ))}
      </div>
      {devices.length > 0 && (
        <div className="lm-strip__devices">
          {devices.map((d) => (
            <figure key={d.name} className="lm-device">
              <img src={d.src} alt={d.alt} loading="lazy" style={{width: d.width}} />
              <figcaption>
                <b>{d.name}</b> · {d.toolkit}
              </figcaption>
            </figure>
          ))}
        </div>
      )}
    </section>
  );
}

/* The two guides, each with the rungs of the ladder it occupies: the user guide
   runs through the water, the developer guide from the intertidal up onto land. */
const GUIDES = [
  {
    to: '/user-guide/getting-started',
    title: 'User guide',
    bars: [
      'var(--chart-depdw)',
      'var(--chart-depmd)',
      'var(--chart-depms)',
      'var(--chart-depvs)',
    ],
    body: 'Turn ENC cells into a chart, open it, and find your way around the display. Getting started, the chart window, moving the chart, mariner settings, raster charts.',
  },
  {
    to: '/developer-guide/architecture',
    title: 'Developer guide',
    bars: [
      'var(--chart-depit)',
      'var(--chart-landa)',
      'var(--chrome-muted)',
      'var(--chrome-ink)',
    ],
    body: 'One Zig core behind a C ABI, with a native shell on each platform. How it fits together, how to build it on your machine, and how to write a plugin.',
  },
];

export function GuideCards() {
  return (
    <section className="lm-cards">
      {GUIDES.map((g) => (
        <Link key={g.title} className="lm-card" to={g.to}>
          <span className="lm-card__bars" aria-hidden="true">
            {g.bars.map((c, i) => (
              <span key={i} style={{background: c}} />
            ))}
          </span>
          <span className="lm-card__title">{g.title}</span>
          <span className="lm-card__body">{g.body}</span>
        </Link>
      ))}
    </section>
  );
}
