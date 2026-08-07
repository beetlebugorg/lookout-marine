import React from 'react';

/**
 * A screenshot with numbered pick markers on it and a legend beneath.
 *
 * The markers use the S-52 mariner magenta — the same colour the app paints a
 * pick in — so a callout on a page reads as the same gesture as a pick in the
 * app. Positions are percentages of the image, not pixels, so the annotation
 * survives the image being served at any width.
 *
 * marks: [{n, x, y, lead}] — x/y locate the centre of the disc; `lead` is the
 * length of the hairline running right from it toward what it names, in the
 * same percentage units. Omit `lead` when the disc already sits on its subject.
 */
export default function AnnotatedShot({src, alt, caption, marks = [], legend = []}) {
  return (
    <figure className="lm-shot-annotated">
      <div className="lm-shot-annotated__frame">
        <img src={src} alt={alt} />
        {marks.map((m) => (
          <React.Fragment key={m.n}>
            {m.lead ? (
              <span
                className="lm-mark__lead"
                style={{left: `${m.x + 1.7}%`, width: `${m.lead}%`, top: `${m.y}%`}}
                aria-hidden="true"
              />
            ) : null}
            <span
              className="lm-mark"
              style={{left: `${m.x}%`, top: `${m.y}%`}}
              aria-hidden="true">
              {m.n}
            </span>
          </React.Fragment>
        ))}
      </div>
      {caption ? (
        <figcaption className="lm-shot-annotated__caption">{caption}</figcaption>
      ) : null}
      {legend.length > 0 && (
        <div className="lm-legend">
          {legend.map((item) => (
            <div className="lm-legend__row" key={item.n}>
              <span className="lm-legend__n">{item.n}</span>
              <div>
                <b>{item.term}</b> {item.body}
              </div>
            </div>
          ))}
        </div>
      )}
    </figure>
  );
}
