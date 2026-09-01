package org.beetlebug.lookout

/**
 * A license read, as values.
 *
 * The core bakes the manifest in, filters it to the shell that asks, and hands
 * it over as structs, so a JVM test has no core to read one from. These are
 * built directly, in the shape the native flattens them into.
 *
 * What the CORE bakes and which entries it keeps for this shell is checked in
 * Zig and, against the real binary, by the device suite. What the SHELL does
 * with a read is checked here.
 */
object LicenseFixture {

    /** One entry: fourteen strings, in the order lookout_license declares. */
    fun entry(
        id: String = "",
        name: String = "",
        group: String = "",
        summary: String = "",
        license: String = "",
        licenseShort: String = "",
        licenseNote: String = "",
        version: String = "",
        commit: String = "",
        pinnedIn: String = "",
        copyright: String = "",
        url: String = "",
        text: String = "",
        notice: String = "",
    ): List<String> = listOf(
        id, name, group, summary, license, licenseShort, licenseNote,
        version, commit, pinnedIn, copyright, url, text, notice,
    )

    /** A read: this app's terms, then the components. */
    fun read(app: List<String>, vararg components: List<String>): Array<String> =
        (app + components.flatMap { it }).toTypedArray()

    val app: List<String> = entry(
        name = "Lookout Marine",
        summary = "A chartplotter.",
        license = "MIT",
        copyright = "© 2026 Jeremy Collins",
        url = "https://beetlebug.org/",
        text = "MIT License\n\nPermission is hereby granted",
    )

    /** A component pinned by commit, in the first group. */
    val tile57: List<String> = entry(
        id = "tile57",
        name = "tile57",
        group = "Chart and rendering",
        summary = "The S-57, S-101 and raster chart engine.",
        license = "MIT",
        licenseShort = "MIT",
        commit = "edcac13f00d",
        pinnedIn = "build.zig.zon",
        copyright = "© 2026 Jeremy Collins",
        url = "https://github.com/beetlebugorg/tile57",
        text = "Permission is hereby granted",
    )

    /** A component whose short form differs from its full one, with a notice. */
    val wamr: List<String> = entry(
        id = "wamr",
        name = "WebAssembly Micro Runtime",
        group = "Plugins",
        summary = "The runtime the plugins execute in.",
        license = "Apache 2.0 with the LLVM exception",
        licenseShort = "Apache-2.0",
        version = "WAMR-2.4.5",
        pinnedIn = "scripts/build-wamr.sh",
        url = "https://github.com/bytecodealliance/wasm-micro-runtime",
        text = "Apache License",
        notice = "This product includes software developed at",
    )

    /** A component whose terms the build could not determine. */
    val s101: List<String> = entry(
        id = "s101",
        name = "IHO S-101 Portrayal Catalogue",
        group = "Images and data",
        summary = "The portrayal rules.",
        licenseNote = "Upstream states no licence.",
        commit = "62f7773aaaa",
        pinnedIn = "tile57's build.zig.zon",
        url = "https://github.com/iho-ohi/S-101_Portrayal-Catalogue",
    )

    val manifest: Array<String> get() = read(app, tile57, wamr, s101)
}
