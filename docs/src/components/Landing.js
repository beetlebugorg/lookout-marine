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

/* The ramp is drawn as one inline SVG rather than six divs, because the band
   edges are curved: a depth contour is a coastline-shaped line, not a rule.
   preserveAspectRatio="none" lets the viewBox stretch to whatever width the
   viewport is, so the curves lengthen rather than repeat, and the height stays
   1:1 with the hero — the wave keeps the same amplitude in pixels at every
   width. Everything stays vector, so it is crisp at any scale. */
const VB_W = 1200;
const VB_H = 560;

/* One meander, shared by every edge. The offsets are fractions of each edge's
   own amplitude, and the two ends are pinned to zero, so a band arrives at both
   margins on its exact proportion — which is also what keeps the legends, and
   the safety contour's label, sitting on their lines.
   The shape is deliberately irregular: a coastline wanders, a sine wave does
   not. Same quadratic vocabulary as assets/brand/lookout-beacon.svg. */
const WAVE = [
  [0.0, 0.0],
  [0.09, -0.55],
  [0.2, -0.95],
  [0.32, -0.25],
  [0.44, 0.65],
  [0.56, 1.0],
  [0.66, 0.45],
  [0.74, -0.35],
  [0.82, -0.7],
  [0.9, -0.3],
  [0.96, -0.05],
  [1.0, 0.0],
];

/* Deep to dry. `top` is the band's upper edge as a percentage of the hero, the
   ramp's proportions from the mockup — not depths. `amp` is how far that edge
   wanders, in pixels of the 560 design: ±9px on the safety contour easing to
   ±5px on the drying line, so the thin intertidal band keeps its thickness.
   `drift` slides the meander sideways a little per edge, so the contours nest
   like real bathymetry instead of running parallel. */
const BANDS = [
  {token: 'var(--chart-depdw)', top: 0},
  {token: 'var(--chart-depmd)', top: 34, amp: 11, drift: 0},
  {token: 'var(--chart-depms)', top: 50, amp: 9, drift: 0.03},
  {token: 'var(--chart-depvs)', top: 64, amp: 9, drift: -0.025},
  {token: 'var(--chart-depit)', top: 76, amp: 6, drift: 0.05},
  {token: 'var(--chart-landa)', top: 82, amp: 5.5, drift: 0.075},
];

/* A smooth chain of quadratics through the meander: each node is a control
   point and the curve runs through the midpoints between them, which is how the
   beacon's bands are drawn. Returns the edge alone — the caller closes it into
   a band or strokes it as a contour. */
function edgePath(top, amp, drift) {
  const baseY = (top / 100) * VB_H;
  const pts = WAVE.map(([t, o], i) => {
    const end = i === 0 || i === WAVE.length - 1;
    return [(end ? t : t + drift) * VB_W, baseY + o * amp];
  });
  /* The last node repeated, so the chain's final curve lands exactly on it. */
  pts.push(pts[pts.length - 1]);

  const n = (v) => Math.round(v * 10) / 10;
  let d = `M ${n(pts[0][0])} ${n(pts[0][1])}`;
  for (let i = 1; i < pts.length - 1; i++) {
    const [cx, cy] = pts[i];
    const [nx, ny] = pts[i + 1];
    d += ` Q ${n(cx)} ${n(cy)} ${n((cx + nx) / 2)} ${n((cy + ny) / 2)}`;
  }
  return d;
}

/* Deepest first, each band filled from its own edge all the way down: the next
   band paints over the surplus. Painter's order, so no seam can open between
   two bands however the curves are tuned. */
function bandPath(b) {
  return `${edgePath(b.top, b.amp, b.drift)} L ${VB_W} ${VB_H} L 0 ${VB_H} Z`;
}

/* Soundings in FEET, whole numbers — a foot sounding is never fractional. Each
   one is plausible for the band it sits in and they shoal band by band toward
   the land, so the ladder reads as a survey and not as decoration.
   Colour is the S-52 rule: SNDG1 (grey) for water deeper than the safety
   contour, SNDG2 (black) for everything inshore of it. The contour is at 34%,
   so `top` alone decides which side a sounding is on.
   Positions avoid the two opaque objects on the ramp: the info panel over the
   left of it, and the guide capsule across the top. */
const SAFETY_CONTOUR_PCT = 34;

const SOUNDINGS = [
  /* DEPDW — deep water, outside the safety contour. Shoaling toward it.
     Nothing sits above 12%: the ramp runs to the top of the page now, and the
     capsule floats there — opaque, and as wide as the viewport at the narrow
     end of the desktop range, so anything higher would be swallowed. Nothing
     to the left of the panel either, for the same reason. */
  {v: '55', left: '58%', top: '13%'},
  {v: '48', left: '76%', top: '12.5%'},
  {v: '39', left: '90%', top: '17%'},
  {v: '42', left: '66%', top: '21%'},
  {v: '31', left: '86%', top: '28%'},
  /* DEPMD — just inshore of the safety contour. */
  {v: '24', left: '79%', top: '40%'},
  {v: '21', left: '62%', top: '44%'},
  /* DEPMS */
  {v: '16', left: '93%', top: '56%'},
  {v: '14', left: '70%', top: '58%'},
  /* DEPVS */
  {v: '9', left: '85%', top: '69%'},
  {v: '7', left: '60%', top: '70%'},
  /* DEPIT — drying heights on the intertidal band. It is the thinnest band and
     its edges now wander, so these sit on the band's centre line. */
  {v: '2', left: '91%', top: '77.6%'},
  /* The panel's bottom edge crosses this band, so the left-hand drying height
     is centred in the sliver of intertidal that shows beneath it. */
  {v: '1', left: '14%', top: '78.4%'},
];

/* The two contours the ramp implies: the safety contour at the top of DEPMD and
   the shoal contour at the top of DEPVS. Each is the band edge it belongs to,
   stroked — a contour and a band edge are the same line on a chart, so they
   wander together. Both cross the whole hero; the info panel is opaque and
   masks the stretch behind it. */
const CONTOURS = [BANDS[1], BANDS[3]];

export function DepthLadderHero() {
  return (
    <section className="lm-hero">
      <svg
        className="lm-hero__bands"
        viewBox={`0 0 ${VB_W} ${VB_H}`}
        preserveAspectRatio="none"
        aria-hidden="true"
        focusable="false">
        {BANDS.map((b) =>
          b.amp === undefined ? (
            /* The deepest band is the ground the rest are painted onto. */
            <rect key={b.token} x="0" y="0" width={VB_W} height={VB_H} style={{fill: b.token}} />
          ) : (
            <path key={b.token} d={bandPath(b)} style={{fill: b.token}} />
          ),
        )}
        {CONTOURS.map((c) => (
          <path
            key={c.token}
            d={edgePath(c.top, c.amp, c.drift)}
            fill="none"
            strokeWidth="1.5"
            vectorEffect="non-scaling-stroke"
            style={{stroke: 'var(--chart-depcn)'}}
          />
        ))}
      </svg>

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
            Download and get started
          </Link>
          <Link className="lm-btn" to="/developer-guide/architecture#building-the-core">
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
    body: 'Install the app, open a folder of ENC cells as one chart, and find your way around the display. Getting started, the chart window, moving the chart, mariner settings, raster charts.',
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
