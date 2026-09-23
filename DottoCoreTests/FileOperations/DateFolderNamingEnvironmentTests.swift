import Foundation

private func namingLocale(_ preferredLanguageIdentifiers: [String], region currentRegionIdentifier: String? = "AR",
                          current currentLocaleIdentifier: String = "en_AR") -> String {
    DateFolderNamingEnvironment.namingLocaleIdentifier(preferredLanguageIdentifiers: preferredLanguageIdentifiers,
                                                       currentRegionIdentifier: currentRegionIdentifier,
                                                       currentLocaleIdentifier: currentLocaleIdentifier)
}

let dateFolderNamingEnvironmentTestSuite = CoreTestSuite(name: "DateFolderNamingEnvironment", testCases: [
    CoreTestCase(name: "the first preferred language names the months, with its own region or else the current one") {
        try expectEqual(namingLocale(["es-AR", "en-US"]), "es_AR")
        try expectEqual(namingLocale(["es", "en-US"]), "es_AR")
        try expectEqual(namingLocale(["es-ES"]), "es_ES")
        try expectEqual(namingLocale(["pt-BR"], region: nil), "pt_BR")
        try expectEqual(namingLocale(["fr"], region: nil), "fr")
        try expectEqual(namingLocale(["zh-Hans-CN"]), "zh_Hans_CN")
        try expectEqual(namingLocale(["zh-hant"], region: "TW"), "zh_Hant_TW")
        try expectEqual(namingLocale(["es-419"]), "es_419")
        try expectEqual(namingLocale(["de-DE-u-ca-gregory"]), "de_DE")
    },
    CoreTestCase(name: "no preferred language, or one that isn't a language tag, falls back to the current locale") {
        try expectEqual(namingLocale([]), "en_AR")
        try expectEqual(namingLocale(["1234"]), "en_AR")
        try expectEqual(namingLocale([""]), "en_AR")
    },
    CoreTestCase(name: "Spanish month names with a Spanish preferred language, and ASCII digits in any language") {
        let spanishEnvironment = DateFolderNamingEnvironment(timeZoneIdentifier: "UTC", localeIdentifier: namingLocale(["es-AR"]),
                                                             calendarIdentifier: "gregorian")
        let monthNameFormatter = DateFolderRuleExpander.makeFormatter(pattern: "MMMM", environment: spanishEnvironment,
                                                                      locale: spanishEnvironment.locale)
        let aprilDate = ISO8601DateFormatter().date(from: "2026-04-15T12:00:00Z") ?? Date()
        try expectEqual(monthNameFormatter.string(from: aprilDate), "abril")
        let arabicEnvironment = DateFolderNamingEnvironment(timeZoneIdentifier: "UTC", localeIdentifier: "ar_EG", calendarIdentifier: "gregorian")
        let yearFormatter = DateFolderRuleExpander.makeFormatter(pattern: "yyyy-MM", environment: arabicEnvironment,
                                                                 locale: arabicEnvironment.digitsLocale)
        try expectEqual(yearFormatter.string(from: aprilDate), "2026-04")
    },
])
