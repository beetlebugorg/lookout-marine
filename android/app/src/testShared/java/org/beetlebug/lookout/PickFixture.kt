package org.beetlebug.lookout

/**
 * A pick read, as values.
 *
 * The engine composes the page and lookout_picks_read hands it over as structs,
 * so a JVM test has no core to read one from. These are built directly, in the
 * shape the native flattens them into.
 *
 * What the CORE composes is checked in Zig, over real cells. What the SHELL
 * does with a read is checked here.
 */
object PickFixture {

    // lookout_pick_empty
    const val READS = 0
    const val NO_ATTRIBUTES = 1
    const val SOURCE_ONLY = 2

    /** One row of the page, or one of the source fold: five strings. */
    fun row(
        label: String,
        value: String = "",
        depth: Int = 0,
        file: Boolean = false,
        picture: Boolean = false,
    ): List<String> = listOf(
        label, value, depth.toString(),
        if (file) "1" else "0",
        if (picture) "1" else "0",
    )

    /** One feature: eleven strings, then its notes, rows and source rows. */
    fun feature(
        cls: String,
        chart: String,
        title: String = "",
        subtitle: String = "",
        chip: String = "",
        footnote: String = "",
        empty: Int = READS,
        raw: String = "",
        notes: List<String> = emptyList(),
        rows: List<List<String>> = emptyList(),
        source: List<List<String>> = emptyList(),
    ): List<String> = listOf(
        cls, chart, title, subtitle, chip, footnote, empty.toString(), raw,
        notes.size.toString(), rows.size.toString(), source.size.toString(),
    ) + notes + rows.flatMap { it } + source.flatMap { it }

    fun read(vararg features: List<String>): Array<String> =
        features.flatMap { it }.toTypedArray()

    /** A light with a note, an indented row and two rows naming files. */
    val light: List<String> get() = feature(
        cls = "LIGHTS",
        chart = "US5MD1MC",
        title = "Thomas Point Shoal Light",
        subtitle = "Fl W 5s 43ft 16M",
        chip = "Light",
        footnote = "US5MD1MC · edition 12",
        raw = """{"OBJNAM":"Thomas Point Shoal Light","LITCHR":2,"SECTR1":[10,20]}""",
        notes = listOf("Restricted area: no anchoring within 100 m."),
        rows = listOf(
            row("Character", "Flashing white"),
            row("Period", "5 s", depth = 1),
            row("Chart note", "US5MD1MC.TXT", file = true),
            row("Photograph", "BRIDGE01.JPG", picture = true),
        ),
        source = listOf(
            row("LITCHR", "2"),
            row("OBJNAM", "Thomas Point Shoal Light"),
            row("SECTR1"),
            row("", "10", depth = 1),
            row("", "20", depth = 1),
        ),
    )

    /** A buoy the compose said nothing about, so the page falls back to the
     *  class and the cell. */
    val bareBuoy: List<String> get() = feature(
        cls = "BOYLAT",
        chart = "US5MD1MC",
        empty = NO_ATTRIBUTES,
        source = listOf(row("COLOUR", "4"), row("OBJNAM", "Green can")),
    )
}
