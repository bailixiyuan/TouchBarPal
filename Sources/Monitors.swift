import AppKit
import CoreLocation
import IOKit.ps
import Darwin

struct SystemSample {
    var batteryPercent: Int?
    var charging = false
    var cpuPercent = 0.0
    var memoryPercent = 0.0
    var downBytesPerSecond = 0.0
    var upBytesPerSecond = 0.0
}

struct WeatherSample {
    var temperature: Int
    var code: Int
}

/// Samples lightweight system stats and the configured city's weather, then
/// hands the results to the bar. Only enabled metrics are measured.
extension Notification.Name {
    static let monitorSettingsChanged = Notification.Name("com.local.touchbarpal.monitorSettingsChanged")
}

final class MonitorCenter: NSObject, CLLocationManagerDelegate {
    static let shared = MonitorCenter()

    var onSystemSample: ((SystemSample) -> Void)?
    var onWeather: ((WeatherSample?) -> Void)?

    private var systemTimer: Timer?
    private var weatherTimer: Timer?
    private var lastTicks: (user: UInt32, system: UInt32, idle: UInt32)?
    private var lastNetwork: (down: UInt64, up: UInt64, date: Date)?
    private var weatherTask: URLSessionDataTask?
    private(set) var batteryUnavailable = false
    private(set) var lastWeather: WeatherSample?
    private let locationManager = CLLocationManager()
    private let geocoder = CLGeocoder()

    override private init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    // MARK: - Scheduling

    func refresh() {
        let settings = AppSettings.shared
        let needsSystem = settings.showCPU || settings.showMemory
            || settings.showNetwork || settings.showBattery
        let needsWeather = settings.showWeather && settings.weatherLatitude != nil

        if needsSystem {
            if systemTimer == nil {
                sampleSystem()
                systemTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                    self?.sampleSystem()
                }
            }
        } else {
            systemTimer?.invalidate()
            systemTimer = nil
        }

        if needsWeather {
            if weatherTimer == nil {
                fetchWeather()
                weatherTimer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
                    self?.fetchWeather()
                }
            } else {
                fetchWeather()
            }
        } else {
            weatherTimer?.invalidate()
            weatherTimer = nil
            onWeather?(nil)
        }
    }

    func invalidate() {
        systemTimer?.invalidate()
        systemTimer = nil
        weatherTimer?.invalidate()
        weatherTimer = nil
        weatherTask?.cancel()
        weatherTask = nil
    }

    // MARK: - System

    private func sampleSystem() {
        let settings = AppSettings.shared
        var sample = SystemSample()

        if settings.showBattery {
            let battery = Self.batteryState()
            batteryUnavailable = battery == nil
            sample.batteryPercent = battery?.percent
            sample.charging = battery?.charging ?? false
        }
        if settings.showCPU {
            sample.cpuPercent = Self.cpuUsage(previous: &lastTicks)
        }
        if settings.showMemory {
            sample.memoryPercent = Self.memoryUsage()
        }
        if settings.showNetwork {
            let now = Date()
            let counters = Self.networkCounters()
            if let lastNetwork {
                let interval = max(now.timeIntervalSince(lastNetwork.date), 0.5)
                sample.downBytesPerSecond = Double(counters.down &- lastNetwork.down) / interval
                sample.upBytesPerSecond = Double(counters.up &- lastNetwork.up) / interval
            }
            lastNetwork = (counters.down, counters.up, now)
        }

        onSystemSample?(sample)
    }

    private static func batteryState() -> (percent: Int, charging: Bool)? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            guard let capacity = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            let charging = (description[kIOPSIsChargingKey] as? Bool) ?? false
            return (Int(Double(capacity) / Double(maximum) * 100), charging)
        }
        return nil
    }

    private static func cpuUsage(previous: inout (user: UInt32, system: UInt32, idle: UInt32)?) -> Double {
        guard let ticks = hostCPUTicks() else { return 0 }
        defer { previous = ticks }
        guard let previous else { return 0 }

        let user = Double(ticks.user &- previous.user)
        let system = Double(ticks.system &- previous.system)
        let idle = Double(ticks.idle &- previous.idle)
        let total = user + system + idle
        guard total > 0 else { return 0 }
        return min(max((user + system) / total * 100, 0), 100)
    }

    private static func hostCPUTicks() -> (user: UInt32, system: UInt32, idle: UInt32)? {
        var count: natural_t = 0
        var infoCount: natural_t = 0
        var info: processor_info_array_t?
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                  &count, &info, &infoCount) == KERN_SUCCESS,
              let info else {
            return nil
        }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        var user: UInt32 = 0
        var system: UInt32 = 0
        var idle: UInt32 = 0
        let stride = Int(CPU_STATE_MAX)
        for cpu in 0..<(Int(infoCount) / stride) {
            user &+= UInt32(bitPattern: info[cpu * stride + Int(CPU_STATE_USER)])
            system &+= UInt32(bitPattern: info[cpu * stride + Int(CPU_STATE_SYSTEM)])
            idle &+= UInt32(bitPattern: info[cpu * stride + Int(CPU_STATE_IDLE)])
        }
        return (user, system, idle)
    }

    private static func memoryUsage() -> Double {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }

        let pageSize = Double(vm_kernel_page_size)
        let used = Double(stats.active_count + stats.inactive_count + stats.wire_count + stats.compressor_page_count) * pageSize
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        guard total > 0 else { return 0 }
        return min(max(used / total * 100, 0), 100)
    }

    private static func networkCounters() -> (down: UInt64, up: UInt64) {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return (0, 0) }
        defer { freeifaddrs(addresses) }

        var down: UInt64 = 0
        var up: UInt64 = 0
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            guard let data = current.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            let name = String(cString: current.pointee.ifa_name)
            if name == "lo0" { continue }
            down &+= UInt64(data.pointee.ifi_ibytes)
            up &+= UInt64(data.pointee.ifi_obytes)
        }
        return (down, up)
    }

    // MARK: - Weather

    func saveCity(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clearLocation()
            return
        }
        geocoder.cancelGeocode()
        geocoder.geocodeAddressString(trimmed) { [weak self] placemarks, error in
            guard let self else { return }
            guard error == nil,
                  let placemark = placemarks?.first,
                  let coordinate = placemark.location?.coordinate else {
                AppSettings.shared.cityName = trimmed + "（未找到）"
                NotificationCenter.default.post(name: .monitorSettingsChanged, object: nil)
                return
            }
            self.apply(coordinate: coordinate, placemark: placemark, fallbackName: trimmed)
        }
    }

    /// Ask Core Location for the current position once. Requires the location
    /// usage description in Info.plist and the user's permission.
    func locateMe() {
        NSApp.activate(ignoringOtherApps: true)
        switch locationManager.authorizationStatus {
        case .authorized, .authorizedAlways:
            locationManager.requestLocation()
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        default:
            NotificationCenter.default.post(
                name: .monitorSettingsChanged,
                object: nil,
                userInfo: ["error": "定位权限未开启，请在系统设置 › 隐私与安全性 › 定位服务中允许 TouchBarPal。"]
            )
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorized, .authorizedAlways:
            manager.requestLocation()
        case .denied, .restricted:
            NotificationCenter.default.post(
                name: .monitorSettingsChanged,
                object: nil,
                userInfo: ["error": "定位权限被拒绝，可在系统设置中开启，或手动输入城市。"]
            )
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        manager.stopUpdatingLocation()
        geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, _ in
            guard let self else { return }
            guard let placemark = placemarks?.first else {
                self.apply(coordinate: location.coordinate, placemark: nil, fallbackName: "当前位置")
                return
            }
            self.apply(coordinate: location.coordinate, placemark: placemark, fallbackName: "当前位置")
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        NotificationCenter.default.post(
            name: .monitorSettingsChanged,
            object: nil,
            userInfo: ["error": "定位失败：\(error.localizedDescription)"]
        )
    }

    private func clearLocation() {
        AppSettings.shared.cityName = ""
        AppSettings.shared.weatherLatitude = nil
        AppSettings.shared.weatherLongitude = nil
        NotificationCenter.default.post(name: .monitorSettingsChanged, object: nil)
        onWeather?(nil)
        refresh()
    }

    private func apply(coordinate: CLLocationCoordinate2D, placemark: CLPlacemark?, fallbackName: String) {
        let label = Self.locationLabel(placemark) ?? fallbackName
        AppSettings.shared.cityName = label
        AppSettings.shared.weatherLatitude = coordinate.latitude
        AppSettings.shared.weatherLongitude = coordinate.longitude
        NotificationCenter.default.post(name: .monitorSettingsChanged, object: nil)
        onWeather?(nil)
        refresh()
    }

    static func locationLabel(_ placemark: CLPlacemark?) -> String? {
        guard let placemark else { return nil }
        var parts: [String] = []
        // Prefer city + district; only keep the province when there is no city.
        if placemark.locality == nil, let area = placemark.administrativeArea, !area.isEmpty {
            parts.append(area)
        }
        for part in [placemark.locality, placemark.subLocality, placemark.thoroughfare] {
            guard let part, !part.isEmpty, parts.last != part else { continue }
            parts.append(part)
        }
        if let street = parts.last, street.count > 12 {
            parts[parts.count - 1] = String(street.prefix(12)) + "…"
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    func fetchWeather() {
        guard AppSettings.shared.showWeather,
              let latitude = AppSettings.shared.weatherLatitude,
              let longitude = AppSettings.shared.weatherLongitude else { return }

        weatherTask?.cancel()
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code"),
            URLQueryItem(name: "timezone", value: "auto")
        ]
        guard let url = components?.url else { return }

        weatherTask = URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let current = json["current"] as? [String: Any],
                  let temperature = current["temperature_2m"] as? Double else { return }
            let code = (current["weather_code"] as? Int) ?? 0
            DispatchQueue.main.async {
                let sample = WeatherSample(temperature: Int(temperature.rounded()), code: code)
                self.lastWeather = sample
                self.onWeather?(sample)
            }
        }
        weatherTask?.resume()
    }

    static func conditionText(for code: Int) -> String {
        switch code {
        case 0: return "晴"
        case 1: return "大致晴"
        case 2: return "局部多云"
        case 3: return "阴"
        case 45, 48: return "雾"
        case 51...57: return "毛毛雨"
        case 61...67: return "雨"
        case 71...77: return "雪"
        case 80...82: return "阵雨"
        case 85, 86: return "阵雪"
        case 95...99: return "雷雨"
        default: return "未知"
        }
    }

    static func symbolName(for code: Int) -> String {
        switch code {
        case 0: return "sun.max.fill"
        case 1, 2: return "cloud.sun.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...57: return "cloud.drizzle.fill"
        case 61...67, 80...82: return "cloud.rain.fill"
        case 71...77, 85, 86: return "cloud.snow.fill"
        case 95...99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    static func speedText(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond < 1000 { return "\(Int(bytesPerSecond))B" }
        if bytesPerSecond < 1024 * 1024 { return String(format: "%.1fK", bytesPerSecond / 1024) }
        return String(format: "%.1fM", bytesPerSecond / (1024 * 1024))
    }
}

/// One compact icon+value badge shown in the bar's monitor strip.
final class MonitorChip: NSView {
    enum Kind: String, CaseIterable {
        case weather, battery, cpu, memory, network
    }

    let kind: Kind
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor

        iconView.imageScaling = .scaleProportionallyDown
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byClipping

        let stack = NSStackView(views: [iconView, label])
        stack.orientation = .horizontal
        stack.spacing = 3
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            iconView.widthAnchor.constraint(equalToConstant: 12),
            iconView.heightAnchor.constraint(equalToConstant: 12)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let textWidth = (label.stringValue as NSString)
            .size(withAttributes: [.font: label.font as Any]).width
        let base: CGFloat = kind == .network ? 34 : 22
        return NSSize(width: min(base + textWidth, 110), height: 24)
    }

    func set(image name: String, text: String) {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        iconView.image = image
        label.stringValue = text
        invalidateIntrinsicContentSize()
    }
}

/// A single Touch Bar item holding all enabled monitor chips. Keeping them in
/// one item avoids the per-item padding that squeezes the app icons.
final class MonitorStripView: NSView {
    var onWeather: (() -> Void)?

    private let stack = NSStackView()
    private var chips: [MonitorChip.Kind: MonitorChip] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func rebuild(enabled: [MonitorChip.Kind]) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        chips.removeAll()

        for kind in enabled {
            let chip = MonitorChip(kind: kind)
            switch kind {
            case .weather: chip.set(image: "cloud.sun.fill", text: "—°")
            case .battery: chip.set(image: "battery.100", text: "--%")
            case .cpu: chip.set(image: "cpu", text: "0%")
            case .memory: chip.set(image: "memorychip", text: "0%")
            case .network: chip.set(image: "arrow.up.arrow.down", text: "↓0B ↑0B")
            }
            stack.addArrangedSubview(chip)
            chips[kind] = chip
        }
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        let width = stack.arrangedSubviews.reduce(CGFloat.zero) { partial, view in
            partial + view.intrinsicContentSize.width
        } + CGFloat(max(stack.arrangedSubviews.count - 1, 0)) * stack.spacing
        return NSSize(width: width, height: 26)
    }

    override func layout() {
        super.layout()
        invalidateIntrinsicContentSize()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let weather = chips[.weather], weather.frame.contains(point) {
            onWeather?()
        }
    }

    func apply(_ sample: SystemSample) {
        if let percent = sample.batteryPercent {
            chips[.battery]?.set(image: sample.charging ? "battery.100.bolt" : batterySymbol(percent),
                                text: "\(percent)%")
        } else {
            chips[.battery]?.set(image: "powerplug.fill", text: "电源")
        }
        chips[.cpu]?.set(image: "cpu", text: "\(Int(sample.cpuPercent.rounded()))%")
        chips[.memory]?.set(image: "memorychip", text: "\(Int(sample.memoryPercent.rounded()))%")
        let text = "↓\(MonitorCenter.speedText(sample.downBytesPerSecond)) ↑\(MonitorCenter.speedText(sample.upBytesPerSecond))"
        chips[.network]?.set(image: "arrow.up.arrow.down", text: text)
    }

    func apply(weather: WeatherSample?) {
        guard let chip = chips[.weather] else { return }
        if let weather {
            chip.set(image: MonitorCenter.symbolName(for: weather.code), text: "\(weather.temperature)°")
        } else {
            chip.set(image: "cloud.sun.fill", text: "—°")
        }
    }

    private func batterySymbol(_ percent: Int) -> String {
        switch percent {
        case ...10: return "battery.0"
        case ...25: return "battery.25"
        case ...50: return "battery.50"
        case ...75: return "battery.75"
        default: return "battery.100"
        }
    }
}
