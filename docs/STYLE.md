# Heading style

This page tells you how to write the headings in `docs/docs/`. Read it before
you add a page, and before you change a heading.

One rule is behind all of the others: **a heading must make sense on its own.**
The reader sees it in the sidebar and in the table of contents, with none of the
text around it. Read each heading you write on its own. If it can mean two
things there, write it again.

## Page titles

Give a page the topic, in plain words. Do not put a verb in it.

Correct: `Raster charts`, `Mariner settings`, `The dev harness`, `Linux`.

The title is in the front matter and in the one h1. The two must agree.

## Section headings

Write a section heading as a gerund phrase. Say what the reader is doing.

Correct:

- `Toggling raster charts`
- `Adding a connection`
- `Reading what it prints`
- `Building and running`

Wrong:

- `Sets` is a bare noun. It does not say what the reader does.
- `Build and run` is an imperative. Use the gerund.
- `Choosing one` raises the question: one what? It is not clear on its own.

A question or a statement is also correct when it is clear on its own, for
example `Why one ABI` or `How the chart gets onto the screen`.

## Name the objects concretely

A heading must name the things it is about. Do not use a count, and do not use
a word that points back at the text. `the three states`, `the two modes`,
`both guides` and `what else` are all wrong: a reader in the table of contents
cannot decode them.

| Wrong | Correct |
|---|---|
| `Seeing the three states` | `Viewing a raster chart under the ENC` |
| `Tuning what else the chart shows` | `Changing the Advanced settings` |
| `The same plugin in Go, and in Rust` | `Building the plugin in Go and in Rust` |

A heading can lean on the page title. It can lean on nothing else. On the page
"The dev harness", `Reading what it prints` is correct, because "it" is the
harness in the title. On the same page, `Running the same loop inside the app`
is wrong, because "the same loop" points at a section further up.

The test does not change: read the heading in the table of contents, with no
other text. Apply the test to the objects too.

## When a noun phrase is permitted

Use a noun phrase in these three cases only.

1. **True reference material.** A table of flags, a table of ABI calls, a list
   of files. Examples: `Flags`, `Event kinds`, `The manifest`.
2. **One short concept introduction for each page.** Use it to say what a thing
   is, before the tasks start. Example: `The core, the shells and the engine`.
3. **One rule for each section, on a page of rules.** Write the rule as a full
   clause. Examples: `Memory is capped at 16 MiB`, `Colours are tokens, never
   RGB`.

The noun phrase must still be clear on its own. A bare noun, such as `Files`,
`Keys`, `Charts` or `Text`, is not clear enough.

## Never use a nickname

Do not use an internal name, or the name of a part of the screen, as a heading.

Wrong: `The pill`, `The capsule`, `The HUD`, `Bubbles`.

Correct: `Toggling raster charts`, `Reading the numbers along the bottom`,
`Using the corner buttons`.

Name the task, or name the thing the reader sees, in plain words. You can still
use the internal name in the text below the heading.

## Heading depth

Use h2 (`##`) for a section. Use h3 (`###`) only when a reader must find one
part of a section on its own. Do not use h4 or deeper. If you need an h4, the
page is too large: make a second page.

Each page has one h1 (`#`), and it is the page title.

## Anchors

Docusaurus makes the anchor from the heading text. When you change a heading,
you change its anchor, and each link to the old anchor breaks.

Do this every time you change a heading.

1. Make the old anchor from the old heading text: lower case, a space becomes
   `-`, and punctuation is removed.
2. Search the whole tree for it.

   ```sh
   grep -rn '#the-old-anchor' docs/docs docs/src
   ```

3. Correct each link that you find.
4. Build the site, and read the output. It must report no broken link and no
   broken anchor.

   ```sh
   cd docs && bun run build
   ```

If you cannot correct a link, because the page that holds it is not yours to edit,
keep the old anchor on the new heading instead:

```md
## Writing the manifest {#the-manifest}
```

## The grammar

The docs use a controlled language, adapted from ASD-STE100 and plain-language
practice. These rules are checkable. Check them.

1. One thought per sentence. An instruction sentence has at most 20 words; a
   description sentence has at most 25.
2. Active voice, present tense. Name the actor. In the plugin guide there are
   exactly two actors: your plugin (you) and Lookout. The SDK appears only
   where the reader meets it: the import line.
3. No em dashes. Use a period, a semicolon, a comma, or a new sentence.
4. Do not define what a developer already knows. Do not explain a thing twice.
   Open a page with the contract, not with definitions.
5. One name per thing, everywhere: Lookout, the SDK, the store, the chart,
   the harness. A second name for the same thing is a defect.
6. No noun clusters over three words. Break them with prepositions.
7. Banned register, with the recorded examples: trailing flourish clauses
   ("…, which is the point"), invented vignettes ("so nobody spends an
   afternoon…"), repetition for rhythm, personified components. Information
   per sentence, no cadence tricks.
8. Technical terms, standard names and code identifiers are the dictionary;
   the rules above do not simplify them away.

**No compressed-pronoun constructions.** "Your declarations take theirs"
saves five words and costs a reread. Spell out both halves: "An event that
belongs to one of your declarations goes to that declaration."

**Name the developer's things as theirs.** "Lookout calls your `draw`
function once a second", never "Lookout calls `draw`". A bare identifier is
not an actor and not an object of a sentence; it is your `draw` function,
your `inputs` declaration, your plugin's scene. When a table lists helper
methods, the prose says they are helper methods. A section heading names what
the reader does with the content, and its first sentence ties the content to
what came before.
