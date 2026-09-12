//  EncTermsSheet.swift
//
//  NOAA's terms, asked once, where NOAA's charts are chosen.
//
//  This used to sit on the empty chart page, which setup replaced. It belongs
//  to the NOAA source rather than to the app: a mariner who draws a published
//  style, or opens their own folder, downloads no ENC and is asked to accept
//  nothing.

import SwiftUI

struct EncTermsSheet: View {
    @Bindable var flow: FirstRunModel

    /// NOAA's agreement itself. The paragraph below summarizes it; this is the
    /// document those words come from.
    static let agreement = URL(string: "https://www.charts.noaa.gov/ENCs/ENC_Agreement.shtml")!

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Before you download")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Chrome.ink)

            StepWarning(
                lead: "NOT FOR NAVIGATION",
                body_: "By importing charts you accept that Lookout is a prototype and not a certified navigation system, and that the charts it prepares are processed for display and are not the official ENC. They do not meet chart carriage regulations. You remain responsible for the safe navigation of your vessel and for keeping clear of every danger. Verify everything shown here against official, up-to-date charts and publications, and keep a paper backup."
            )

            // NOAA's own terms, in their words. They apply to their charts
            // whoever prepared them.
            Text("NOAA ENC® charts come from the NOAA Office of Coast Survey and are updated weekly on a best-efforts basis; you are responsible for holding the current edition and the latest updates. NOAA makes no warranty and assumes no liability for their use. See the [NOAA ENC User Agreement](https://www.charts.noaa.gov/ENCs/ENC_Agreement.shtml).")
                .font(.system(size: 11.5))
                .lineSpacing(2)
                .foregroundStyle(Chrome.muted)
                .fixedSize(horizontal: false, vertical: true)
                .tint(Chrome.accent)

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { flow.declineEncTerms() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("enc-terms-cancel")
                Button("Agree and Continue") { flow.agreeToEncTerms() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("enc-terms-agree")
                    #if os(macOS)
                    .buttonStyle(.borderedProminent)
                    #endif
            }
        }
        .padding(20)
        .frame(maxWidth: 520)
        .background(Chrome.surface)
        .accessibilityIdentifier("enc-terms")
    }
}
