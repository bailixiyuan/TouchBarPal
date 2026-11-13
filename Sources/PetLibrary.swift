import AppKit

/// A pet package: either the built-in capybara or an imported 8×9 spritesheet
/// with a pet.json beside it. The animation rows are shared across every pet.
struct PetAsset: Equatable {
    let id: String
    let name: String
    /// Nil for the built-in pet, which ships inside the app bundle.
    let directory: URL?

    var isBuiltIn: Bool { directory == nil }

    var sheetURL: URL? {
        if let directory {
            let json = directory.appendingPathComponent("pet.json")
            if let data = try? Data(contentsOf: json),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let path = object["spritesheetPath"] as? String {
                return directory.appendingPathComponent(path)
            }
            for ext in ["webp", "png", "jpg", "jpeg"] {
                let candidate = directory.appendingPathComponent("spritesheet.\(ext)")
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            }
            return nil
        }
        return Bundle.main.url(forResource: "spritesheet", withExtension: "webp")
    }

    static let builtIn = PetAsset(id: "capybara-lulu", name: "水豚噜噜", directory: nil)
}

enum PetImportError: LocalizedError {
    case notAFolder
    case missingManifest
    case missingSheet
    case badSheet

    var errorDescription: String? {
        switch self {
        case .notAFolder: return "请选择一个包含 pet.json 和精灵图的文件夹。"
        case .missingManifest: return "文件夹里没有有效的 pet.json（需要 displayName 和 spritesheetPath）。"
        case .missingSheet: return "pet.json 指向的精灵图不存在。"
        case .badSheet: return "精灵图需要是至少 8 列 × 9 行的透明图片。"
        }
    }
}

/// Installed pets live under Application Support; the built-in one always comes
/// first and cannot be deleted.
final class PetLibrary {
    static let shared = PetLibrary()

    private let fileManager = FileManager.default

    private var root: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("TouchBarPal/Pets", isDirectory: true)
    }

    private init() {}

    var pets: [PetAsset] {
        var result = [PetAsset.builtIn]
        let directories = (try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        for directory in directories.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let asset = asset(in: directory) else { continue }
            result.append(asset)
        }
        return result
    }

    func selected() -> PetAsset {
        let all = pets
        let id = AppSettings.shared.selectedPetID
        return all.first { $0.id == id } ?? .builtIn
    }

    func asset(withID id: String) -> PetAsset? {
        pets.first { $0.id == id }
    }

    private func asset(in directory: URL) -> PetAsset? {
        let json = directory.appendingPathComponent("pet.json")
        guard let data = try? Data(contentsOf: json),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["displayName"] as? String, !name.isEmpty,
              let path = object["spritesheetPath"] as? String,
              fileManager.fileExists(atPath: directory.appendingPathComponent(path).path)
        else { return nil }
        return PetAsset(id: directory.lastPathComponent, name: name, directory: directory)
    }

    @discardableResult
    func importPackage(from directory: URL) throws -> PetAsset {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw PetImportError.notAFolder }

        let json = directory.appendingPathComponent("pet.json")
        guard let data = try? Data(contentsOf: json),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["displayName"] as? String, !name.isEmpty,
              let relative = object["spritesheetPath"] as? String
        else { throw PetImportError.missingManifest }

        let sheet = directory.appendingPathComponent(relative)
        guard fileManager.fileExists(atPath: sheet.path) else { throw PetImportError.missingSheet }
        guard let image = NSImage(contentsOf: sheet) else { throw PetImportError.badSheet }
        var proposed = NSRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil),
              cg.width % 8 == 0 else { throw PetImportError.badSheet }
        let cellWidth = cg.width / 8
        let cellHeight = Int((Double(cellWidth) * 13.0 / 12.0).rounded())
        guard cellWidth >= 8, cellHeight > 0 else { throw PetImportError.badSheet }
        let rows = cg.height / cellHeight
        let tolerance = max(1, cellHeight / 100)
        guard rows >= 9, abs(cg.height - rows * cellHeight) <= tolerance
        else { throw PetImportError.badSheet }

        // Keep a filesystem-safe slug plus a short suffix for uniqueness.
        let slug = name.replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
            .lowercased()
            .prefix(24)
        let id = "\(slug)-\(UUID().uuidString.prefix(6).lowercased())"
        let destination = root.appendingPathComponent(id, isDirectory: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let sheetName = "spritesheet.\(sheet.pathExtension.lowercased())"
        try fileManager.copyItem(at: sheet, to: destination.appendingPathComponent(sheetName))
        let manifest = ["displayName": name, "spritesheetPath": sheetName]
        let manifestData = (try? JSONSerialization.data(withJSONObject: manifest)) ?? data
        try manifestData.write(to: destination.appendingPathComponent("pet.json"))
        return PetAsset(id: id, name: name, directory: destination)
    }

    func remove(_ asset: PetAsset) throws {
        guard let directory = asset.directory else { return }
        try fileManager.removeItem(at: directory)
    }
}
