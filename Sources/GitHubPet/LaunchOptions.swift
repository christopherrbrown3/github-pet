import Foundation
import GitHubPetCore

/// Command-line and environment hooks for development and QA.
///
///   --defaults-suite <name>       isolate preferences (or GITHUB_PET_DEFAULTS_SUITE)
///   --reset-settings              start from default settings
///   --fixtures | --gh             force the data source for this launch
///   --inject-event-after <secs>   inject one fixture entitlement event after a delay
///   --start-time <ISO8601>        app clock starts at this instant (or GITHUB_PET_START_TIME)
///   --clock-offset <secs>         shift the app clock (or GITHUB_PET_CLOCK_OFFSET)
///   GITHUB_PET_GH_PATH=<path>     use this gh executable (missing/fake gh testing)
///   --render-snapshots <dir>      render a fixture scenario offscreen to PNG + AX report, then quit;
///                                 always fixtures, default settings and a throwaway preferences suite
///   --placeholder                 draw the native placeholder instead of the bundled pack
///   GITHUB_PET_PACK_DIR=<dir>     load this mascot pack instead of the bundled one
struct LaunchOptions {
    var defaultsSuite: String?
    var resetSettings = false
    var forcedSource: String?
    var injectEventAfter: TimeInterval?
    var packDirectory: URL?
    var forcePlaceholder = false
    var snapshotDirectory: URL?
    /// Added to the wall clock for every snooze, quiet-hours and freshness decision.
    var clockOffset: TimeInterval = 0

    static func parse(arguments: [String] = CommandLine.arguments,
                      environment: [String: String] = ProcessInfo.processInfo.environment) -> LaunchOptions {
        var options = LaunchOptions()
        options.defaultsSuite = environment["GITHUB_PET_DEFAULTS_SUITE"]
        if let dir = environment["GITHUB_PET_PACK_DIR"], !dir.isEmpty {
            options.packDirectory = URL(fileURLWithPath: dir, isDirectory: true)
        }
        func startOffset(_ text: String?) -> TimeInterval? {
            guard let text, let start = ISO8601DateFormatter().date(from: text) else { return nil }
            return start.timeIntervalSinceNow
        }
        if let offset = environment["GITHUB_PET_CLOCK_OFFSET"].flatMap(TimeInterval.init) { options.clockOffset = offset }
        if let offset = startOffset(environment["GITHUB_PET_START_TIME"]) { options.clockOffset = offset }
        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--defaults-suite": options.defaultsSuite = iterator.next()
            case "--reset-settings": options.resetSettings = true
            case "--placeholder": options.forcePlaceholder = true
            case "--render-snapshots":
                if let dir = iterator.next() { options.snapshotDirectory = URL(fileURLWithPath: dir, isDirectory: true) }
            case "--fixtures": options.forcedSource = "fixtures"
            case "--gh": options.forcedSource = "gh"
            case "--inject-event-after":
                options.injectEventAfter = iterator.next().flatMap(TimeInterval.init)
            case "--clock-offset":
                if let offset = iterator.next().flatMap(TimeInterval.init) { options.clockOffset = offset }
            case "--start-time":
                if let offset = startOffset(iterator.next()) { options.clockOffset = offset }
            default: break
            }
        }
        // Snapshot evidence is shared, so it must never contain live GitHub data or touch the
        // user's preferences: force Demo fixtures and fresh settings in a throwaway suite,
        // whatever other flags or saved settings say. Applied before AppModel exists.
        if options.snapshotDirectory != nil {
            options.forcedSource = "fixtures"
            options.defaultsSuite = Self.snapshotDefaultsSuite
            options.resetSettings = true
        }
        return options
    }

    /// Pack to load: explicit override, else the copy bundled in the .app, else (for
    /// `swift run`) the repository's pack found above the `.build` directory.
    func resolvedPackDirectory(bundle: Bundle = .main,
                               executable: URL = URL(fileURLWithPath: CommandLine.arguments[0])) -> URL? {
        if forcePlaceholder { return nil }
        if let packDirectory { return packDirectory }
        let id = MascotPack.defaultPackID
        if let bundled = bundle.resourceURL?.appendingPathComponent("MascotPacks/\(id)", isDirectory: true),
           FileManager.default.fileExists(atPath: bundled.appendingPathComponent("manifest.json").path) {
            return bundled
        }
        var dir = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        while dir.path != "/" {
            if dir.lastPathComponent == ".build" {
                let pack = dir.deletingLastPathComponent().appendingPathComponent("assets/mascots/\(id)", isDirectory: true)
                return FileManager.default.fileExists(atPath: pack.appendingPathComponent("manifest.json").path) ? pack : nil
            }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    static let snapshotDefaultsSuite = "dev.github-pet.render-snapshots.\(ProcessInfo.processInfo.processIdentifier)"

    var userDefaults: UserDefaults {
        if let defaultsSuite, !defaultsSuite.isEmpty, let suite = UserDefaults(suiteName: defaultsSuite) {
            return suite
        }
        return .standard
    }
}
