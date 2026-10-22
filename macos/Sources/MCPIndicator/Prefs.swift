import Foundation

/// Mesmas chaves do schema GSettings da extensão GNOME, guardadas em UserDefaults.
enum PrefKey {
    static let refreshInterval = "refreshInterval"
    static let showStopped = "showStopped"
    static let showOrphans = "showOrphans"
    static let probeRemote = "probeRemote"
    static let enableNotifications = "enableNotifications"
    static let extraConfigPaths = "extraConfigPaths"
    static let showCountInMenuBar = "showCountInMenuBar"
}

enum Prefs {
    static let defaults = UserDefaults.standard

    static func register() {
        defaults.register(defaults: [
            PrefKey.refreshInterval: 5,
            PrefKey.showStopped: true,
            PrefKey.showOrphans: true,
            PrefKey.probeRemote: false,
            PrefKey.enableNotifications: true,
            PrefKey.extraConfigPaths: [String](),
            PrefKey.showCountInMenuBar: true,
        ])
    }

    static var refreshInterval: Int { min(60, max(3, defaults.integer(forKey: PrefKey.refreshInterval))) }
    static var showStopped: Bool { defaults.bool(forKey: PrefKey.showStopped) }
    static var showOrphans: Bool { defaults.bool(forKey: PrefKey.showOrphans) }
    static var probeRemote: Bool { defaults.bool(forKey: PrefKey.probeRemote) }
    static var enableNotifications: Bool { defaults.bool(forKey: PrefKey.enableNotifications) }
    static var showCountInMenuBar: Bool { defaults.bool(forKey: PrefKey.showCountInMenuBar) }

    struct Signature: Equatable {
        let scan: [String]
        let view: [Bool]
        let interval: Int
    }

    static var signature: Signature {
        Signature(
            scan: extraConfigPaths + [String(probeRemote)],
            view: [showStopped, showOrphans, showCountInMenuBar, enableNotifications],
            interval: refreshInterval
        )
    }

    static var extraConfigPaths: [String] {
        get { defaults.stringArray(forKey: PrefKey.extraConfigPaths) ?? [] }
        set { defaults.set(newValue, forKey: PrefKey.extraConfigPaths) }
    }
}
