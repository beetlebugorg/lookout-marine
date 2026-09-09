//  LabelFont.swift — the face for scripts the bundled label font has no glyphs for.
//
//  tile57 bundles Noto Sans, which covers Latin, Greek and Cyrillic. A chart
//  naming its features in another script — an S-57 cell's NOBJNM, an S-101
//  dataset's own languages — wants glyphs no bundled face carries: CJK alone is
//  some 20,000, more than the atlas has room for and far more than one chart
//  uses. Apple ships those faces already, so nothing is bundled here.
//
//  The shell finds the file and the core takes the bytes, the same division as
//  the cache directory. The core reports the characters a label could not draw
//  and bakes exactly those, so opening a 60 MB face costs a mapping, not a
//  rasterization.
//
//  COVERING THE CHARACTER IS NOT ENOUGH. CoreText answers "what would I draw
//  this with", and on macOS that is PingFang UI, whose outlines live in Apple's
//  own `cidg` table rather than glyf or CFF. The glyph baker reads nothing out
//  of it and every label comes out blank. So each candidate is put to
//  lookout_font_covers, which asks the baker itself, and the first face that
//  answers is the one installed.

import CoreText
import Foundation

enum LabelFont {
    /// The mapped file of a face that can draw `sample`'s first character, or
    /// nil when this system has none the baker can read.
    static func faceCovering(_ sample: String) -> Data? {
        guard let scalar = sample.unicodeScalars.first else { return nil }
        for url in candidates(for: sample) {
            // Mapped, not read: these files run to tens of megabytes and only
            // the few glyphs a chart names are ever touched.
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  !data.isEmpty else { continue }
            let held = data as NSData
            let usable = lookout_font_covers(
                held.bytes.assumingMemoryBound(to: UInt8.self), held.length, scalar.value) == 1
            if usable {
                lkLog("label fallback face: \(url.lastPathComponent) (\(data.count) bytes)")
                return data
            }
        }
        return nil
    }

    /// The font files this system offers for `sample`, best first.
    ///
    /// CoreText's cascade answer leads, because it is the face the mariner
    /// reads everywhere else on the device. Behind it come every installed
    /// face whose character set has the sample, which is where the static
    /// TrueType CJK faces are found when the UI font cannot be baked.
    private static func candidates(for sample: String) -> [URL] {
        var urls: [URL] = []
        var seen = Set<String>()
        func add(_ font: CTFont) {
            guard let url = CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL else { return }
            if seen.insert(url.path).inserted { urls.append(url) }
        }

        let base = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        let text = sample as NSString
        add(CTFontCreateForString(base, text, CFRangeMake(0, text.length)))

        var set = CharacterSet()
        set.insert(charactersIn: sample)
        let want = [kCTFontCharacterSetAttribute as String: set as NSCharacterSet]
        let desc = CTFontDescriptorCreateWithAttributes(want as CFDictionary)
        let keys = Set([kCTFontCharacterSetAttribute as String]) as NSSet
        let matches = CTFontDescriptorCreateMatchingFontDescriptors(
            desc, keys as CFSet) as? [CTFontDescriptor] ?? []
        for d in matches { add(CTFontCreateWithFontDescriptor(d, 12, nil)) }
        return urls
    }

    /// A character `code` is written with, to test a face against.
    ///
    /// From the system's own exemplar set for the language rather than a table
    /// kept here: a table is a list of the scripts someone thought of, and the
    /// one it is missing is the one a chart turns up in. ISO 639-2 is what a
    /// chart states and BCP-47 is what Locale takes, so the code is converted
    /// first. `und` is an S-57 national name, which states no language at all
    /// and so has no exemplar; those cells are overwhelmingly CJK, and a
    /// national name in a Latin script needs no other face anyway.
    static func probe(for code: String) -> Unicode.Scalar? {
        if code == "und" { return Unicode.Scalar(0x6C49) }  // 汉
        let bcp47 = Locale.LanguageCode(code).identifier(.alpha2) ?? code
        guard let set = Locale(identifier: bcp47).exemplarCharacterSet else { return nil }
        // The first character outside ASCII: what the language needs beyond
        // what every face already draws.
        for v in 0x00A0...0x1FFFF {
            if let sc = Unicode.Scalar(UInt32(v)), set.contains(sc) { return sc }
        }
        return nil
    }

    /// The face to hand the core for a library stating `codes`.
    ///
    /// A language the bundled face already draws is passed over. A chart
    /// naming its features in Finnish, Inuktitut, Inari Sami and Swedish needs
    /// a face for the syllabics and nothing else; taking the languages in
    /// order and stopping at the first found a Latin face for Finnish and left
    /// the Inuktitut blank.
    ///
    /// ONE face, so a library that genuinely mixes two scripts the bundled
    /// font lacks draws the first and leaves the second blank. That is the
    /// same as before this rather than worse, and no chart in the S-101 test
    /// sets does it.
    static func forLanguages(_ codes: [String]) -> Data? {
        for code in codes {
            guard let scalar = probe(for: code) else { continue }
            if lookout_label_font_covers(scalar.value) == 1 { continue }
            if let data = faceCovering(String(scalar)) { return data }
        }
        return nil
    }
}
