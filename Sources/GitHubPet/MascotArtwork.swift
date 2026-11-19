import Foundation
import GitHubPetCore

struct MascotArtwork {
    enum Source: Equatable {
        case builtIn(MascotSkin), custom, placeholder
    }

    let source: Source
    let pack: MascotPack?
    var notice: String?
    var errors: [MascotPackError] = []
    var locksPicker = false

    var logDescription: String {
        pack.map { "mascot pack \($0.manifest.displayID) loaded from \(PackLabel.sanitizePath($0.directory.path))" }
            ?? (errors.isEmpty ? "mascot placeholder (no pack)"
                : "mascot placeholder (pack rejected: \(errors.map(\.description).joined(separator: "; ")))")
    }
}

/// Resolves launch overrides before the built-in choice. Only the two verified built-in results
/// are cached, so switching between them does not reopen any validated frame path.
struct MascotArtworkLoader {
    let forcePlaceholder: Bool
    let overrideDirectory: URL?
    let builtInDirectory: (MascotSkin) -> URL?
    private var builtIns: [MascotSkin: Result<MascotPack, MascotPackErrors>] = [:]

    init(options: LaunchOptions, builtInDirectory: @escaping (MascotSkin) -> URL?) {
        forcePlaceholder = options.forcePlaceholder
        overrideDirectory = options.packDirectory
        self.builtInDirectory = builtInDirectory
    }

    mutating func resolve(_ skin: MascotSkin) -> MascotArtwork {
        if forcePlaceholder {
            return MascotArtwork(source: .placeholder, pack: nil, notice: "This launch uses the placeholder.",
                                 locksPicker: true)
        }
        if let overrideDirectory {
            switch MascotPack.load(from: overrideDirectory) {
            case .success(let pack):
                return MascotArtwork(source: .custom, pack: pack,
                                     notice: "Using custom pack \(pack.manifest.displayName) for this launch.",
                                     locksPicker: true)
            case .failure(let failure):
                return MascotArtwork(source: .placeholder, pack: nil,
                                     notice: "Custom pack rejected. Showing the placeholder.",
                                     errors: failure.errors, locksPicker: true)
            }
        }

        switch loadBuiltIn(skin) {
        case .success(let pack):
            return MascotArtwork(source: .builtIn(skin), pack: pack)
        case .failure(let failure):
            if skin == .littleChris, case .success(let mona) = loadBuiltIn(.mona) {
                return MascotArtwork(source: .builtIn(.mona), pack: mona,
                                     notice: "Little Chris is unavailable. Showing Mona.", errors: failure.errors)
            }
            return MascotArtwork(source: .placeholder, pack: nil,
                                 notice: "\(skin.name) is unavailable. Showing the placeholder.", errors: failure.errors)
        }
    }

    private mutating func loadBuiltIn(_ skin: MascotSkin) -> Result<MascotPack, MascotPackErrors> {
        if let cached = builtIns[skin] { return cached }
        let result: Result<MascotPack, MascotPackErrors>
        if let directory = builtInDirectory(skin) {
            result = MascotPack.load(from: directory, expectedID: skin.rawValue)
        } else {
            result = .failure(MascotPackErrors(errors: [.unreadableManifest]))
        }
        builtIns[skin] = result
        return result
    }
}
