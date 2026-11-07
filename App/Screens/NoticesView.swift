import SwiftUI

/// Licences of what ships inside the app: the Manrope font (SIL OFL 1.1).
struct NoticesView: View {
    @Environment(\.theme) private var theme

    private static let manropeLicence: String = {
        guard let url = Bundle.main.url(forResource: "OFL", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "" }
        return text
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s3) {
                Text("Manrope")
                    .textRole(.title)
                    .foregroundStyle(theme.ink)
                Text(Self.manropeLicence)
                    .textRole(.caption)
                    .foregroundStyle(theme.ink2)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.inset)
        }
        .background(theme.canvas)
        .navigationTitle("Open-Source Notices")
        .navigationBarTitleDisplayMode(.inline)
    }
}
