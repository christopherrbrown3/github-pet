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
///   --simulate-monitoring-scope  opt-in offline scope controls, fresh throwaway defaults, no network
///   --placeholder                 draw the native placeholder instead of the bundled pack
///   --placeholder-clips           #138 QA: add "PH" placeholder clips, held poses and hat to the pack
///   GITHUB_PET_PACK_DIR=<dir>     load this mascot pack instead of the bundled one
///   --replay-clips <secs>         #138 dev: play the pack's clips in turn every <secs> s, without touching data;
///                                 ignored by the production bundle ID
///   --dump-incident-frames <dir>  #138 dev: what both skins show at every frame while an incident is
///                                 active (overlay and helmet counts, contact sheets), then quit
///                                 (in-memory preferences; ignored by the production bundle ID)
struct LaunchOptions {
    var defaultsSuite: String?
    var resetSettings = false
    var forcedSource: String?
    var injectEventAfter: TimeInterval?
    var packDirectory: URL?
    var forcePlaceholder = false
    var placeholderClips = false
    var replayClipsEvery: TimeInterval?
    var dumpIncidentFrames: URL?
    var snapshotDirectory: URL?
    /// Explicit opt-in: offline simulated accounts, isolated defaults and manual polling.
    var simulatesMonitoringScope = false
    /// QA scenario runner (QAScenarioRunner); refused unless simulatesMonitoringScope.
    var qaScenario: String?
    var qaOutput: String?
    /// Added to the wall clock for every snooze, quiet-hours and freshness decision.
    var clockOffset: TimeInterval = 0

    /// The shipping app's identifier: dev-only hooks stay off there.
    static let productionBundleID = "dev.github-pet.GitHubPet"

    /// `bundleIdentifier` is a test seam: the dev-only hooks are dropped under `productionBundleID`.
    static func parse(arguments: [String] = CommandLine.arguments,
                      environment: [String: String] = ProcessInfo.processInfo.environment,
                      bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> LaunchOptions {
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
            case "--placeholder-clips": options.placeholderClips = true
            case "--dump-incident-frames":
                if let dir = iterator.next() { options.dumpIncidentFrames = URL(fileURLWithPath: dir, isDirectory: true) }
            case "--replay-clips":
                options.replayClipsEvery = iterator.next().flatMap(TimeInterval.init).map { max($0, 2) }
            case "--render-snapshots":
                if let dir = iterator.next() { options.snapshotDirectory = URL(fileURLWithPath: dir, isDirectory: true) }
            case "--simulate-monitoring-scope": options.simulatesMonitoringScope = true
            case "--qa-scenario": options.qaScenario = iterator.next() ?? ""
            case "--qa-output": options.qaOutput = iterator.next() ?? ""
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
        if bundleIdentifier == Self.productionBundleID {
            options.replayClipsEvery = nil
            options.dumpIncidentFrames = nil
        }
        if options.dumpIncidentFrames != nil {
            // Nothing of the user's: fixtures and an in-memory preferences domain.
            options.forcedSource = "fixtures"
            options.defaultsSuite = Self.dumpDefaultsSuite
            options.resetSettings = true
        }
        // Snapshot evidence is shared, so it must never contain live GitHub data or touch the
        // user's preferences: force Demo fixtures and fresh settings in a throwaway suite,
        // whatever other flags or saved settings say. Applied before AppModel exists.
        if options.simulatesMonitoringScope {
            options.forcedSource = "gh"
            options.defaultsSuite = "dev.github-pet.scope-simulation.\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString)"
            options.resetSettings = true
        }
        if options.snapshotDirectory != nil {
            options.simulatesMonitoringScope = false
            options.forcedSource = "fixtures"
            options.defaultsSuite = Self.snapshotDefaultsSuite
            options.resetSettings = true
        }
        return options
    }

    /// A packaged app reads its own resources. A raw SwiftPM executable can also use the checkout.
    static func builtInPackDirectory(for skin: MascotSkin, bundle: Bundle = .main,
                                     executable: URL = URL(fileURLWithPath: CommandLine.arguments[0])) -> URL? {
        let id = skin.rawValue
        let bundled = bundle.resourceURL?.appendingPathComponent("MascotPacks/\(id)", isDirectory: true)
        if bundle.bundleURL.pathExtension == "app" { return bundled }
        if let bundled, FileManager.default.fileExists(atPath: bundled.path) {
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
    static let dumpDefaultsSuite = "dev.github-pet.dump-clip-frames.\(ProcessInfo.processInfo.processIdentifier)"

    /// Test seam: an in-memory store for a normal (non-simulated) launch.
    var userDefaultsOverride: UserDefaults?

    var userDefaults: UserDefaults {
        if let userDefaultsOverride { return userDefaultsOverride }
        // The simulated launch's throwaway domain lives only in memory: nothing reaches disk.
        if simulatesMonitoringScope, let defaultsSuite, defaultsSuite.hasPrefix("dev.github-pet.scope-simulation.") {
            return EphemeralDefaults.named(defaultsSuite)
        }
        // Snapshot renders also use a throwaway domain; a real suite left an empty
        // render-snapshots.<pid>.plist behind on every run, even after removePersistentDomain.
        if snapshotDirectory != nil, defaultsSuite == Self.snapshotDefaultsSuite {
            return EphemeralDefaults.named(Self.snapshotDefaultsSuite)
        }
        if dumpIncidentFrames != nil, defaultsSuite == Self.dumpDefaultsSuite {
            return EphemeralDefaults.named(Self.dumpDefaultsSuite)
        }
        if let defaultsSuite, !defaultsSuite.isEmpty, let suite = UserDefaults(suiteName: defaultsSuite) {
            return suite
        }
        return .standard
    }
}
