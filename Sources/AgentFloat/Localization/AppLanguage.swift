import AppKit
import Observation
import Synchronization

enum AppLanguage: String, CaseIterable, Sendable {
    case ko, en

    var endonym: String {
        switch self {
        case .ko: "한국어"
        case .en: "English"
        }
    }

    static func resolve(saved: String?, override: String?, preferred: [String]) -> AppLanguage {
        if let override, let language = Self(rawValue: override) { return language }
        if let saved, let language = Self(rawValue: saved) { return language }
        return preferred.first?.lowercased().hasPrefix("ko") == true ? .ko : .en
    }
}

@MainActor @Observable
final class LanguageSettings {
    nonisolated private static let snapshotValue = Mutex<AppLanguage>(.en)
    nonisolated static var snapshot: AppLanguage { snapshotValue.withLock { $0 } }
    static let shared = LanguageSettings()
    private(set) var language: AppLanguage
    var strings: Strings { language == .ko ? .ko : .en }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let override: String?
    @ObservationIgnored var onChange: (() -> Void)?

    init(defaults: UserDefaults = .standard, environment: [String: String] = ProcessInfo.processInfo.environment,
         preferred: [String] = Locale.preferredLanguages) {
        self.defaults = defaults
        override = environment["AGENT_FLOAT_LANGUAGE"]
        language = AppLanguage.resolve(saved: defaults.string(forKey: "language"), override: override, preferred: preferred)
        if defaults === UserDefaults.standard { Self.snapshotValue.withLock { $0 = language } }
    }

    func select(_ language: AppLanguage) {
        defaults.set(language.rawValue, forKey: "language")
        self.language = AppLanguage.resolve(saved: language.rawValue, override: override, preferred: [])
        if defaults === UserDefaults.standard { Self.snapshotValue.withLock { $0 = self.language } }
        onChange?()
    }
}
