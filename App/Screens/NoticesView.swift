import SwiftUI
#if canImport(Libavutil)
import Libavutil
#endif

/// Licences of what ships inside the app, each on its own page. The video engine's section exists only
/// in builds that link the engine; there FFmpeg also reports the version it was built from.
struct NoticesView: View {
    @Environment(\.theme) private var theme

    var body: some View {
        List {
            Section {
                ForEach(Notice.app) { notice in
                    link(notice)
                }
            }
            .listRowBackground(theme.sheet)
            #if canImport(Libavutil)
            Section {
                ForEach(Notice.engine) { notice in
                    link(notice)
                }
            } header: {
                Text("Video Engine")
            } footer: {
                Text(Notice.ffmpegBuild)
                    .foregroundStyle(theme.ink2)
            }
            .listRowBackground(theme.sheet)
            #endif
        }
        .themedList(theme)
        .navigationTitle("Open-Source Notices")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func link(_ notice: Notice) -> some View {
        NavigationLink {
            LicenceTextView(notice: notice)
        } label: {
            LabeledContent(notice.name) {
                Text(notice.licence)
                    .foregroundStyle(theme.ink2)
            }
        }
        .accessibilityIdentifier("notice.\(notice.id)")
    }
}

/// A component and the bundled texts of its licence.
private struct Notice: Identifiable {
    let id: String
    let name: String
    let licence: String
    /// Paths inside the app bundle, shown in this order.
    let files: [String]

    static let app = [
        Notice(id: "marquee", name: "Marquee", licence: "MIT", files: ["LICENSE"]),
        Notice(id: "manrope", name: "Manrope", licence: "SIL OFL 1.1", files: ["OFL.txt"]),
    ]

    #if canImport(Libavutil)
    /// `Licences/engine` is the LICENSES.zip of the linked stashy-videoengine release; update the two together.
    static let engine = [
        Notice(id: "ffmpeg", name: "FFmpeg", licence: "LGPL 2.1 or later", files: [
            "Licences/engine/NOTICE.txt", "Licences/engine/BUILDINFO.txt",
            "Licences/engine/ffmpeg/COPYING.LGPLv2.1", "Licences/engine/ffmpeg/LICENSE.md",
        ]),
        Notice(id: "dav1d", name: "dav1d", licence: "BSD 2-Clause", files: ["Licences/engine/dav1d/COPYING"]),
        Notice(id: "freetype", name: "FreeType", licence: "FreeType License", files: [
            "Licences/engine/freetype/LICENSE.TXT", "Licences/engine/freetype/FTL.TXT",
        ]),
        Notice(id: "fribidi", name: "FriBiDi", licence: "LGPL 2.1 or later", files: ["Licences/engine/fribidi/COPYING"]),
        Notice(id: "harfbuzz", name: "HarfBuzz", licence: "MIT", files: ["Licences/engine/harfbuzz/COPYING"]),
        Notice(id: "libass", name: "libass", licence: "ISC", files: ["Licences/engine/libass/COPYING"]),
        Notice(id: "zimg", name: "zimg", licence: "WTFPL", files: ["Licences/engine/zimg/COPYING"]),
        Notice(id: "videoengine", name: "stashy-videoengine", licence: "MIT", files: ["Licences/engine/stashy-videoengine/LICENSE"]),
    ]

    /// FFmpeg's own account of the build that is linked in, e.g. "FFmpeg n9.0.2, LGPL version 2.1 or later".
    static var ffmpegBuild: String {
        "FFmpeg \(String(cString: av_version_info())), \(String(cString: avutil_license()))"
    }
    #endif

    /// The bundled files in order, as paragraphs reflowed for the screen.
    var paragraphs: [String] {
        files
            .compactMap { file in
                Bundle.main.resourceURL.flatMap { try? String(contentsOf: $0.appending(path: file), encoding: .utf8) }
            }
            .flatMap(LicenceText.paragraphs)
    }
}

private struct LicenceTextView: View {
    let notice: Notice

    @Environment(\.theme) private var theme
    @State private var paragraphs: [String] = []

    var body: some View {
        ScrollView {
            // The LGPL alone is some 500 lines, so paragraphs lay out as they scroll in.
            LazyVStack(alignment: .leading, spacing: Space.s3) {
                ForEach(paragraphs.indices, id: \.self) { index in
                    Text(paragraphs[index])
                        .textRole(.caption)
                        .foregroundStyle(theme.ink2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .textSelection(.enabled)
            .padding(Space.inset)
        }
        .background(theme.canvas)
        .navigationTitle(notice.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { paragraphs = notice.paragraphs }
    }
}
