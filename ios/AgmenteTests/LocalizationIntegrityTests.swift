import XCTest
@testable import Agmente

/// W2-AC-501, W2-AC-502 & SC-AC-011: Static localization catalog integrity, 8-language completeness,
/// zero `ja` allowlist, CLDR plural completeness, placeholder consistency, and brand unification.
final class LocalizationIntegrityTests: XCTestCase {

    private var iosRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private let requiredLanguages: Set<String> = ["en", "zh-Hans", "zh-Hant", "ko", "ru", "es", "fr", "de"]
    private let forbiddenLanguageKeys: Set<String> = ["ja", "ja-JP", "ja-jp"]

    // MARK: - W2-AC-501: Catalog, InfoPlist, pbxproj knownRegions & Display Name

    func testW2AC501_CatalogsPbxprojAndInfoPlistIntegrity() throws {
        // 1. project.pbxproj: knownRegions == 8 languages + Base, zero ja, CFBundleDisplayName == Nonlocal
        let pbxprojURL = iosRoot.appendingPathComponent("Agmente.xcodeproj/project.pbxproj")
        let pbxproj = try String(contentsOf: pbxprojURL, encoding: .utf8)

        let knownRegionsRegex = try NSRegularExpression(pattern: #"knownRegions\s*=\s*\(([^)]*)\);"#)
        let nsPbx = pbxproj as NSString
        let regionMatch = try XCTUnwrap(
            knownRegionsRegex.firstMatch(in: pbxproj, range: NSRange(location: 0, length: nsPbx.length)),
            "knownRegions not found in project.pbxproj"
        )
        let regionBody = nsPbx.substring(with: regionMatch.range(at: 1))
        let parsedRegions = Set(
            regionBody
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
                .filter { !$0.isEmpty }
        )
        let expectedRegions = requiredLanguages.union(["Base"])
        XCTAssertEqual(parsedRegions, expectedRegions, "knownRegions must match exact 8 languages + Base (zero ja)")
        XCTAssertTrue(parsedRegions.isDisjoint(with: forbiddenLanguageKeys))

        // CFBundleDisplayName == Nonlocal, zero Gofer
        XCTAssertTrue(pbxproj.contains("INFOPLIST_KEY_CFBundleDisplayName = Nonlocal;"))
        XCTAssertFalse(pbxproj.contains("INFOPLIST_KEY_CFBundleDisplayName = Gofer;"))

        // 2. Info.plist: zero Agmente/Gofer
        let infoPlistURL = iosRoot.appendingPathComponent("Agmente/Info.plist")
        let infoPlist = try String(contentsOf: infoPlistURL, encoding: .utf8)
        XCTAssertFalse(infoPlist.contains("Agmente"), "Info.plist must not contain Agmente")
        XCTAssertFalse(infoPlist.contains("Gofer"), "Info.plist must not contain Gofer")
        XCTAssertTrue(infoPlist.contains("Nonlocal"))

        // 3. InfoPlist.xcstrings: both permission keys present & 8-language translated, zero ja, zero Agmente/Gofer
        let infoPlistCatalogURL = iosRoot.appendingPathComponent("Agmente/Resources/InfoPlist.xcstrings")
        let infoCatalog = try loadCatalog(at: infoPlistCatalogURL)
        XCTAssertNotNil(infoCatalog["NSPhotoLibraryUsageDescription"], "InfoPlist.xcstrings must contain NSPhotoLibraryUsageDescription")
        XCTAssertNotNil(infoCatalog["NSLocalNetworkUsageDescription"], "InfoPlist.xcstrings must contain NSLocalNetworkUsageDescription")
        try validateCatalog(infoCatalog, catalogName: "InfoPlist.xcstrings")

        // 4. Localizable.xcstrings: 8-language translated, CLDR plurals, placeholders, zero ja, zero Agmente/Gofer
        let localizableCatalogURL = iosRoot.appendingPathComponent("Agmente/Resources/Localizable.xcstrings")
        let localizableCatalog = try loadCatalog(at: localizableCatalogURL)
        XCTAssertGreaterThan(localizableCatalog.count, 100, "Localizable.xcstrings must not be empty")
        try validateCatalog(localizableCatalog, catalogName: "Localizable.xcstrings")

        // Verify CLDR plural completeness on "%lld files changed"
        let filesChangedEntry = try XCTUnwrap(
            localizableCatalog["%lld files changed"] as? [String: Any],
            "Localizable.xcstrings must contain plural key '%lld files changed'"
        )
        let fcLocs = try XCTUnwrap(filesChangedEntry["localizations"] as? [String: Any])
        for lang in requiredLanguages {
            let langObj = try XCTUnwrap(fcLocs[lang] as? [String: Any], "Missing \(lang) in '%lld files changed'")
            let variations = try XCTUnwrap(langObj["variations"] as? [String: Any], "Missing variations in \(lang)")
            let plural = try XCTUnwrap(variations["plural"] as? [String: Any], "Missing plural in \(lang)")
            let expectedForms: Set<String>
            switch lang {
            case "ru": expectedForms = ["one", "few", "many", "other"]
            case "en", "es", "fr", "de": expectedForms = ["one", "other"]
            default: expectedForms = ["other"]
            }
            let actualForms = Set(plural.keys)
            XCTAssertTrue(
                expectedForms.isSubset(of: actualForms),
                "CLDR plural forms for \(lang) missing: expected \(expectedForms), got \(actualForms)"
            )
        }
    }

    // MARK: - W2-AC-502: Source scans for zero residual Chinese/Agmente/Gofer & intact internal byte anchors

    func testW2AC502_SourceScanAndInternalByteAnchors() throws {
        let agmenteDir = iosRoot.appendingPathComponent("Agmente")
        let fm = FileManager.default
        let enumerator = try XCTUnwrap(fm.enumerator(at: agmenteDir, includingPropertiesForKeys: nil))

        let cjkRegex = try NSRegularExpression(pattern: #"[\u4e00-\u9fff]"#)
        let stringLitRegex = try NSRegularExpression(pattern: #""([^"\\]*(?:\\.[^"\\]*)*)""#)
        let brandRegex = try NSRegularExpression(pattern: #"\b(Agmente|Gofer)\b"#)

        let allowedInternalBrandLiterals: Set<String> = [
            "Agmente iOS",
            "Agmente.lastServerId",
            "Agmente.devModeEnabled",
            "Agmente.codexSessionLoggingEnabled",
            "Agmente.useHighPerformanceChatRenderer",
            "Agmente.codexPermissionPreset.",
            "Agmente.clientId",
            "Agmente.lastConnectedAt",
            "Agmente",
            "Agmente.momd",
        ]

        var cjkViolations: [String] = []
        var brandViolations: [String] = []

        while let fileURL = enumerator.nextObject() as? URL {
            guard fileURL.pathExtension == "swift" else { continue }
            let fileName = fileURL.lastPathComponent
            // Whitelisted file: AppLocalization autonym table
            if fileName == "AppLocalization.swift" {
                continue
            }
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            var inPreview = false
            for (idx, rawLine) in content.components(separatedBy: .newlines).enumerated() {
                let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#Preview") { inPreview = true }
                if inPreview { continue }
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("*") { continue }
                let codePart = rawLine.components(separatedBy: "//").first ?? rawLine
                let nsCode = codePart as NSString
                let matches = stringLitRegex.matches(in: codePart, range: NSRange(location: 0, length: nsCode.length))
                for m in matches {
                    let lit = nsCode.substring(with: m.range(at: 1))
                    let nsLit = lit as NSString
                    if cjkRegex.firstMatch(in: lit, range: NSRange(location: 0, length: nsLit.length)) != nil {
                        cjkViolations.append("\(fileName):\(idx + 1): \(lit)")
                    }
                    if brandRegex.firstMatch(in: lit, range: NSRange(location: 0, length: nsLit.length)) != nil {
                        if !allowedInternalBrandLiterals.contains(lit) {
                            brandViolations.append("\(fileName):\(idx + 1): \(lit)")
                        }
                    }
                }
            }
        }

        XCTAssertTrue(cjkViolations.isEmpty, "Unexpected Chinese string literals in ios/Agmente: \(cjkViolations.prefix(10))")
        XCTAssertTrue(brandViolations.isEmpty, "Unexpected user-facing Agmente/Gofer literals: \(brandViolations.prefix(10))")

        // Verify internal byte anchors remain intact
        let appVM = try String(contentsOf: agmenteDir.appendingPathComponent("AppViewModel.swift"), encoding: .utf8)
        XCTAssertTrue(appVM.contains("\"Agmente iOS\""), "ACP clientName must remain 'Agmente iOS'")
        XCTAssertTrue(appVM.contains("\"Agmente.lastServerId\""), "UserDefaults key must remain 'Agmente.lastServerId'")

        let supplemental = try String(contentsOf: agmenteDir.appendingPathComponent("SessionSupplementalViews.swift"), encoding: .utf8)
        XCTAssertTrue(supplemental.contains("\"Tool call: "), "Internal 'Tool call:' prefix must remain intact")
        XCTAssertFalse(supplemental.contains("/aɡˈmen.te/"), "Legacy phonetic subtitle must be removed")

        let settings = try String(contentsOf: agmenteDir.appendingPathComponent("SettingsView.swift"), encoding: .utf8)
        XCTAssertFalse(settings.contains("halliharp.com"), "SettingsView must not contain halliharp.com feedback links")

        // Verify ACPClient package contains zero .xcstrings
        for pkg in ["ACPClient"] {
            let pkgDir = iosRoot.appendingPathComponent(pkg)
            if let pkgEnum = fm.enumerator(at: pkgDir, includingPropertiesForKeys: nil) {
                while let url = pkgEnum.nextObject() as? URL {
                    XCTAssertNotEqual(url.pathExtension, "xcstrings", "\(pkg) must not contain .xcstrings")
                }
            }
        }

        // Verify AppLocalization fallback behavior for ja -> en
        XCTAssertEqual(AppLocalization.resolveLanguageCode(preferredLocalizations: ["ja-JP"]), "en")
        XCTAssertEqual(AppLocalization.resolveLanguageCode(preferredLocalizations: ["ja"]), "en")
        XCTAssertEqual(AppLocalization.resolveLanguageCode(preferredLocalizations: ["zh-Hans-CN"]), "zh-Hans")
        XCTAssertEqual(AppLocalization.resolveLanguageCode(preferredLocalizations: ["zh-TW"]), "zh-Hant")
        XCTAssertEqual(AppLocalization.resolveLanguageCode(preferredLocalizations: ["de-DE"]), "de")
        XCTAssertFalse(AppLocalization.supportedLanguageCodes.contains("ja"))
    }

    // MARK: - Helpers

    private func loadCatalog(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["strings"] as? [String: Any])
    }

    private func validateCatalog(_ strings: [String: Any], catalogName: String) throws {
        let placeholderRegex = try NSRegularExpression(pattern: #"%(?:\d+\$)?(?:@|lld|ld|d|f|u)"#)
        let brandRegex = try NSRegularExpression(pattern: #"\b(Agmente|Gofer)\b"#)

        func placeholders(in text: String) -> [String] {
            let ns = text as NSString
            return placeholderRegex
                .matches(in: text, range: NSRange(location: 0, length: ns.length))
                .map { ns.substring(with: $0.range) }
                .sorted()
        }

        for (key, rawEntry) in strings {
            guard let entry = rawEntry as? [String: Any] else { continue }
            if let shouldTranslate = entry["shouldTranslate"] as? Bool, !shouldTranslate {
                continue
            }
            let locs = try XCTUnwrap(entry["localizations"] as? [String: Any], "\(catalogName) key '\(key)' missing localizations")
            let locKeys = Set(locs.keys)
            XCTAssertTrue(
                locKeys.isDisjoint(with: forbiddenLanguageKeys),
                "\(catalogName) key '\(key)' must not contain forbidden ja locale"
            )
            XCTAssertTrue(
                requiredLanguages.isSubset(of: locKeys),
                "\(catalogName) key '\(key)' missing languages: \(requiredLanguages.subtracting(locKeys))"
            )

            let expectedPlaceholders = placeholders(in: key)
            for lang in requiredLanguages {
                guard let langDict = locs[lang] as? [String: Any] else { continue }
                var unitValues: [String] = []
                if let unit = langDict["stringUnit"] as? [String: Any] {
                    XCTAssertEqual(unit["state"] as? String, "translated", "\(catalogName) [\(lang)] '\(key)' must be translated")
                    let val = try XCTUnwrap(unit["value"] as? String)
                    XCTAssertFalse(val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(catalogName) [\(lang)] '\(key)' is empty")
                    unitValues.append(val)
                } else if let variations = langDict["variations"] as? [String: Any],
                          let plural = variations["plural"] as? [String: Any] {
                    for (form, rawBranch) in plural {
                        let branch = try XCTUnwrap(rawBranch as? [String: Any])
                        let unit = try XCTUnwrap(branch["stringUnit"] as? [String: Any])
                        XCTAssertEqual(unit["state"] as? String, "translated", "\(catalogName) [\(lang).\(form)] '\(key)' must be translated")
                        let val = try XCTUnwrap(unit["value"] as? String)
                        XCTAssertFalse(val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        unitValues.append(val)
                    }
                } else {
                    XCTFail("\(catalogName) [\(lang)] '\(key)' missing stringUnit or variations.plural")
                }

                for val in unitValues {
                    let nsVal = val as NSString
                    XCTAssertNil(
                        brandRegex.firstMatch(in: val, range: NSRange(location: 0, length: nsVal.length)),
                        "\(catalogName) [\(lang)] '\(key)' contains forbidden brand name: \(val)"
                    )
                    if !expectedPlaceholders.isEmpty {
                        XCTAssertEqual(
                            placeholders(in: val),
                            expectedPlaceholders,
                            "\(catalogName) [\(lang)] '\(key)' placeholder mismatch: got '\(val)'"
                        )
                    }
                }
            }
        }
    }
}
