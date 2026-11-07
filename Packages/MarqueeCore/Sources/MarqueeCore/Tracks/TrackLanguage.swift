import Foundation

/// The language of a track, normalised so `eng`, `en` and `en-US` compare as English.
public struct TrackLanguage: Sendable, Hashable, Codable {
    /// ISO 639-1 where one exists (`en`), otherwise ISO 639-2 (`fil`); nil when unknown.
    public var code: String?
    /// Script subtag, e.g. `Hant`.
    public var script: String?
    /// Region subtag, e.g. `GB` or `419`.
    public var region: String?

    public init(code: String?, script: String? = nil, region: String? = nil) {
        self.code = code
        self.script = script
        self.region = region
    }

    public static let english = TrackLanguage(code: "en")

    /// Parses a BCP 47 tag (`pt-BR`, `zh-Hant`) or an ISO 639 code (`jpn`, `fre`).
    public init(tag: String?) {
        let parts = (tag ?? "").split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
        guard let first = parts.first else {
            self.init(code: nil)
            return
        }
        var script: String?
        var region: String?
        for part in parts.dropFirst() {
            if part.count == 4, part.allSatisfy(\.isLetter) {
                script = part.prefix(1).uppercased() + part.dropFirst().lowercased()
            } else if (part.count == 2 && part.allSatisfy(\.isLetter)) || (part.count == 3 && part.allSatisfy(\.isNumber)) {
                region = part.uppercased()
            }
        }
        self.init(code: Self.normalized(first), script: script, region: region)
    }

    public init(stream: PlexStream) {
        if let tag = stream.languageTag, !tag.isEmpty {
            self.init(tag: tag)
        } else {
            self.init(tag: stream.languageCode)
        }
    }

    public var isKnown: Bool { code != nil }

    /// Same language, whatever the region or script. Unknown matches nothing.
    public func matches(_ other: TrackLanguage) -> Bool {
        code != nil && code == other.code
    }

    /// English name of the language, e.g. "Japanese"; nil when unknown.
    public var name: String? {
        code.flatMap { Self.displayLocale.localizedString(forLanguageCode: $0) }
    }

    /// The region or script in words, e.g. "Latin America", "Traditional Han".
    public var variantName: String? {
        if let region { return Self.displayLocale.localizedString(forRegionCode: region) ?? region }
        if let script { return Self.displayLocale.localizedString(forScriptCode: script) ?? script }
        return nil
    }

    private static let displayLocale = Locale(identifier: "en_US")

    private static func normalized(_ code: String) -> String? {
        let code = code.lowercased()
        guard code.allSatisfy(\.isLetter), (2...3).contains(code.count), !unknownCodes.contains(code) else { return nil }
        return code.count == 3 ? (alpha2[code] ?? code) : code
    }

    private static let unknownCodes: Set<String> = ["und", "unk", "mis", "mul", "zxx", "xx"]

    /// ISO 639-2 (both terminology and bibliographic forms) to ISO 639-1.
    private static let alpha2: [String: String] = {
        let pairs = """
        aar aa abk ab afr af aka ak alb sq amh am ara ar arg an arm hy asm as ava av ave ae aym ay aze az \
        bak ba bam bm baq eu bel be ben bn bis bi bod bo bos bs bre br bul bg bur my cat ca ces cs cha ch \
        che ce chi zh chu cu chv cv cor kw cos co cre cr cym cy cze cs dan da deu de div dv dut nl dzo dz \
        ell el eng en epo eo est et eus eu ewe ee fao fo fas fa fij fj fin fi fra fr fre fr fry fy ful ff \
        geo ka ger de gla gd gle ga glg gl glv gv gre el grn gn guj gu hat ht hau ha heb he her hz hin hi \
        hmo ho hrv hr hun hu hye hy ibo ig ice is ido io iii ii iku iu ile ie ina ia ind id ipk ik isl is \
        ita it jav jv jpn ja kal kl kan kn kas ks kat ka kau kr kaz kk khm km kik ki kin rw kir ky kom kv \
        kon kg kor ko kua kj kur ku lao lo lat la lav lv lim li lin ln lit lt ltz lb lub lu lug lg mac mk \
        mah mh mal ml mao mi mar mr may ms mkd mk mlg mg mlt mt mon mn mri mi msa ms mya my nau na nav nv \
        nbl nr nde nd ndo ng nep ne nld nl nno nn nob nb nor no nya ny oci oc oji oj ori or orm om oss os \
        pan pa per fa pli pi pol pl por pt pus ps que qu roh rm ron ro rum ro run rn rus ru sag sg san sa \
        sin si slk sk slo sk slv sl sme se smo sm sna sn snd sd som so sot st spa es sqi sq srd sc srp sr \
        ssw ss sun su swa sw swe sv tah ty tam ta tat tt tel te tgk tg tgl tl tha th tib bo tir ti ton to \
        tsn tn tso ts tuk tk tur tr twi tw uig ug ukr uk urd ur uzb uz ven ve vie vi vol vo wel cy wln wa \
        wol wo xho xh yid yi yor yo zha za zho zh zul zu
        """.split(separator: " ").map(String.init)
        let entries = stride(from: 0, to: pairs.count - 1, by: 2).map { (pairs[$0], pairs[$0 + 1]) }
        return Dictionary(entries, uniquingKeysWith: { first, _ in first })
    }()
}
