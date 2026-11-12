import Foundation

/// Command-line and environment hooks for development and QA.
///
///   --defaults-suite <name>       isolate preferences (or GITHUB_PET_DEFAULTS_SUITE)
///   --reset-settings              start from default settings
///   --fixtures | --gh             force the data source for this launch
///   --inject-event-after <secs>   inject one fixture entitlement event after a delay
///   --start-time <ISO8601>        app clock starts at this instant (or GITHUB_PET_START_TIME)
///   --clock-offset <secs>         shift the app clock (or GITHUB_PET_CLOCK_OFFSET)
///   GITHUB_PET_GH_PATH=<path>     use this gh executable (missing/fake gh testing)
///   GITHUB_PET_PACK_DIR=<dir>     load a mascot pack instead of the placeholder
struct LaunchOptions {
    var defaultsSuite: String?
    var resetSettings = false
    var forcedSource: String?
    var injectEventAfter: TimeInterval?
    var packDirectory: URL?
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
        return options
    }

    var userDefaults: UserDefaults {
        if let defaultsSuite, !defaultsSuite.isEmpty, let suite = UserDefaults(suiteName: defaultsSuite) {
            return suite
        }
        return .standard
    }
}
