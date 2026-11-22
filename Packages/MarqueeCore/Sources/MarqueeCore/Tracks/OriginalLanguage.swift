import Foundation

/// The language a title was made in, by the countries Plex lists for it. Plex spells countries as ISO 3166
/// names ("Republic of Korea", "Taiwan, Province of China", "Russian Federation"), so the table holds each
/// form it has been seen to use beside the short name.
public enum OriginalLanguage {
    /// The languages to look for in a file's audio for a title made in `countries`, in the order the
    /// countries are listed; a country that is unknown to the table adds none.
    public static func languages(countries: [String]) -> [[TrackLanguage]] {
        countries.compactMap { table[normalized($0)] }.map { $0.map { TrackLanguage(code: $0) } }
    }

    /// The first track in the language of the first country that has one.
    static func firstMatch(among tracks: [AudioTrack], countries: [String]) -> AudioTrack? {
        for candidates in languages(countries: countries) {
            for language in candidates {
                let matching = tracks.filter { $0.language.matches(language) }
                if let track = matching.first(where: \.isDefault) ?? matching.first { return track }
            }
        }
        return nil
    }

    private static func normalized(_ country: String) -> String {
        country.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Country to the language codes of its audio, best first. Hong Kong lists Cantonese (`yue`) ahead of
    /// the Chinese a file tags Mandarin with.
    private static let table: [String: [String]] = {
        let rows: [([String], [String])] = [
            (["United States", "United States of America", "USA", "US", "United Kingdom", "UK", "Great Britain",
              "Canada", "Australia", "New Zealand", "Ireland"], ["en"]),
            (["Japan"], ["ja"]),
            (["South Korea", "Republic of Korea", "Korea, Republic of", "Korea", "North Korea",
              "Korea, Democratic People's Republic of", "Democratic People's Republic of Korea"], ["ko"]),
            (["China", "People's Republic of China", "Taiwan", "Taiwan, Province of China", "Republic of China"], ["zh"]),
            (["Hong Kong", "Hong Kong SAR China", "Macao", "Macau"], ["yue", "zh"]),
            (["France"], ["fr"]),
            (["Germany", "Austria"], ["de"]),
            (["Italy"], ["it"]),
            (["Spain", "Mexico", "Argentina", "Colombia", "Chile", "Peru", "Venezuela", "Uruguay", "Cuba"], ["es"]),
            (["Brazil", "Portugal"], ["pt"]),
            (["Russia", "Russian Federation", "Soviet Union", "USSR"], ["ru"]),
            (["India"], ["hi"]),
            (["Denmark"], ["da"]),
            (["Sweden"], ["sv"]),
            (["Norway"], ["no", "nb"]),
            (["Finland"], ["fi"]),
            (["Iceland"], ["is"]),
            (["Netherlands", "The Netherlands"], ["nl"]),
            (["Poland"], ["pl"]),
            (["Czech Republic", "Czechia"], ["cs"]),
            (["Hungary"], ["hu"]),
            (["Romania"], ["ro"]),
            (["Greece"], ["el"]),
            (["Turkey", "Türkiye"], ["tr"]),
            (["Ukraine"], ["uk"]),
            (["Israel"], ["he"]),
            (["Iran", "Iran, Islamic Republic of", "Islamic Republic of Iran"], ["fa"]),
            (["Thailand"], ["th"]),
            (["Vietnam", "Viet Nam"], ["vi"]),
            (["Indonesia"], ["id"]),
            (["Philippines"], ["tl", "fil"]),
        ]
        var table: [String: [String]] = [:]
        for (countries, languages) in rows {
            for country in countries { table[normalized(country)] = languages }
        }
        return table
    }()
}
