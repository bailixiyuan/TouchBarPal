import AppKit

enum BarMode: String {
    /// Most-recently-used apps, in the order they were activated.
    case recent
    /// A hand-picked, manually ordered list.
    case custom
}

/// User preferences for what may appear on the bar. Everything is stored in
/// `UserDefaults` under the app's own domain.
final class AppSettings {
    static let shared = AppSettings()

    /// Fired whenever a preference changes so the bar can redraw.
    var onChange: (() -> Void)?

    private let defaults = UserDefaults.standard
    private let modeKey = "barMode"
    private let countKey = "recentLimit"
    private let hiddenKey = "hiddenBundleIDs"
    private let customKey = "customBundleIDs"
    private let showWeatherKey = "monitorWeather"
    private let showBatteryKey = "monitorBattery"
    private let showCPUKey = "monitorCPU"
    private let showMemoryKey = "monitorMemory"
    private let showNetworkKey = "monitorNetwork"
    private let cityKey = "weatherCity"
    private let latitudeKey = "weatherLatitude"
    private let longitudeKey = "weatherLongitude"
    private let showPetKey = "showPet"
    private let selectedPetKey = "selectedPetID"

    static let defaultRecentLimit = 12
    static let maximumRecentLimit = 14

    private init() {}

    var mode: BarMode {
        get { BarMode(rawValue: defaults.string(forKey: modeKey) ?? "") ?? .recent }
        set {
            defaults.set(newValue.rawValue, forKey: modeKey)
            notify()
        }
    }

    var recentLimit: Int {
        get {
            let stored = defaults.integer(forKey: countKey)
            return stored == 0 ? Self.defaultRecentLimit : min(stored, Self.maximumRecentLimit)
        }
        set {
            defaults.set(max(0, min(newValue, Self.maximumRecentLimit)), forKey: countKey)
            notify()
        }
    }

    // MARK: - Monitors

    private func bool(_ key: String, default fallback: Bool) -> Bool {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return defaults.bool(forKey: key)
    }

    var showWeather: Bool {
        get { bool(showWeatherKey, default: true) }
        set { defaults.set(newValue, forKey: showWeatherKey); notify() }
    }

    var showBattery: Bool {
        get { bool(showBatteryKey, default: true) }
        set { defaults.set(newValue, forKey: showBatteryKey); notify() }
    }

    var showCPU: Bool {
        get { bool(showCPUKey, default: true) }
        set { defaults.set(newValue, forKey: showCPUKey); notify() }
    }

    var showMemory: Bool {
        get { bool(showMemoryKey, default: true) }
        set { defaults.set(newValue, forKey: showMemoryKey); notify() }
    }

    var showNetwork: Bool {
        get { bool(showNetworkKey, default: false) }
        set { defaults.set(newValue, forKey: showNetworkKey); notify() }
    }

    // MARK: - Pet

    var showPet: Bool {
        get { bool(showPetKey, default: true) }
        set { defaults.set(newValue, forKey: showPetKey); notify() }
    }

    var selectedPetID: String {
        get { defaults.string(forKey: selectedPetKey) ?? PetAsset.builtIn.id }
        set { defaults.set(newValue, forKey: selectedPetKey); notify() }
    }

    var cityName: String {
        get { defaults.string(forKey: cityKey) ?? "" }
        set { defaults.set(newValue, forKey: cityKey) }
    }

    var weatherLatitude: Double? {
        get { defaults.object(forKey: latitudeKey) as? Double }
        set {
            if let newValue { defaults.set(newValue, forKey: latitudeKey) }
            else { defaults.removeObject(forKey: latitudeKey) }
        }
    }

    var weatherLongitude: Double? {
        get { defaults.object(forKey: longitudeKey) as? Double }
        set {
            if let newValue { defaults.set(newValue, forKey: longitudeKey) }
            else { defaults.removeObject(forKey: longitudeKey) }
        }
    }

    // MARK: - Hidden apps

    private(set) var hiddenBundleIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: hiddenKey) ?? []) }
        set { defaults.set(Array(newValue), forKey: hiddenKey) }
    }

    func isHidden(_ bundleID: String) -> Bool {
        hiddenBundleIDs.contains(bundleID)
    }

    func setHidden(_ hidden: Bool, for bundleID: String) {
        var ids = hiddenBundleIDs
        if hidden {
            ids.insert(bundleID)
        } else {
            ids.remove(bundleID)
        }
        hiddenBundleIDs = ids
        notify()
    }

    // MARK: - Custom order

    var customBundleIDs: [String] {
        get { defaults.stringArray(forKey: customKey) ?? [] }
        set { defaults.set(newValue, forKey: customKey) }
    }

    func isInCustomList(_ bundleID: String) -> Bool {
        customBundleIDs.contains(bundleID)
    }

    func setInCustomList(_ included: Bool, for bundleID: String) {
        var ids = customBundleIDs
        ids.removeAll { $0 == bundleID }
        if included {
            ids.append(bundleID)
        }
        customBundleIDs = ids
        notify()
    }

    func moveCustomItem(from source: Int, to destination: Int) {
        var ids = customBundleIDs
        guard source >= 0, source < ids.count else { return }
        let value = ids.remove(at: source)
        ids.insert(value, at: min(destination, ids.count))
        customBundleIDs = ids
        notify()
    }

    var isEmptyCustomList: Bool {
        customBundleIDs.isEmpty
    }

    private func notify() {
        if batchDepth > 0 {
            batchPending = true
            return
        }
        onChange?()
    }

    private var batchDepth = 0
    private var batchPending = false

    /// Groups several preference writes into a single `onChange` callback.
    func batch(_ body: () -> Void) {
        batchDepth += 1
        body()
        batchDepth -= 1
        guard batchDepth == 0, batchPending else { return }
        batchPending = false
        onChange?()
    }
}
