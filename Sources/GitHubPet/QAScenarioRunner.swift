import AppKit
import GitHubPetCore
import SwiftUI

/// Functional-QA hook: `--simulate-monitoring-scope --qa-scenario <name|path.json> --qa-output <dir>`.
/// Drives the same AppModel actions the Inbox, Simulated scope menu and Settings controls call,
/// then writes per step what a user would see: `step-NN-<label>.json` plus offscreen PNGs of the
/// app's own Inbox, mascot and (on `open-settings`) Settings views. No Screen Recording or
/// Accessibility permission, no gh process or network. It never asserts pass/fail; QA judges the
/// output. Non-zero exit means a harness error only (refused flags, bad scenario, timeout).
///
/// Scenario JSON: `{"name": "...", "steps": [{"action": "hold", "count": 2, "label": "two-held"}, ...]}`.
/// Every key is validated per action; unknown actions or keys fail before the app model exists.
@MainActor
enum QAScenarioRunner {
    struct Plan {
        let name: String
        let steps: [Step]
        let output: URL
        let clock = QAScenarioClock()
        /// Harness bound only: exceeding it is a harness error, never a scenario verdict.
        var settleLimit: Duration = .seconds(30)
        var rendersPNGs = true
        var runtime: AppModel.Runtime {
            // Scenario clock drives app time (clips, freshness); command budgets stay on the system
            // clock. Timers are off: the runner ticks after each step instead.
            AppModel.Runtime(now: { [clock] in clock.now() }, schedulesTimers: false)
        }
    }
    struct Step {
        let action: String
        let label: String
        let params: [String: Any]
    }
    struct HarnessError: Error, CustomStringConvertible { let description: String }

    static let markerName = ".github-pet-qa-runner"
    private(set) static var plan: Plan?

    // MARK: Preflight (before any AppModel or defaults domain exists)

    /// Called from App.init. Exits non-zero, writing nothing, if runner flags are misused.
    static func preflight(arguments: [String] = CommandLine.arguments) {
        let options = LaunchOptions.parse(arguments: arguments)
        guard options.qaScenario != nil || options.qaOutput != nil else { return }
        do { plan = try makePlan(options) } catch {
            FileHandle.standardError.write(Data("GitHubPet QA runner: refused: \(error)\n".utf8))
            exit(2)
        }
    }

    static func makePlan(_ options: LaunchOptions) throws -> Plan {
        guard options.simulatesMonitoringScope else {
            throw HarnessError(description: "--qa-scenario/--qa-output require --simulate-monitoring-scope; nothing was run or written")
        }
        guard let scenario = options.qaScenario, !scenario.isEmpty else { throw HarnessError(description: "--qa-scenario <name|path.json> is required") }
        guard let output = options.qaOutput, !output.isEmpty else { throw HarnessError(description: "--qa-output <dir> is required") }
        let (name, steps) = try loadScenario(scenario)
        return Plan(name: name, steps: steps, output: try checkOutput(output))
    }

    static func loadScenario(_ reference: String) throws -> (String, [Step]) {
        let data: Data
        if let builtIn = builtInScenarios[reference] {
            data = Data(builtIn.utf8)
        } else if reference.hasSuffix(".json") {
            do { data = try Data(contentsOf: URL(fileURLWithPath: reference)) } catch {
                throw HarnessError(description: "cannot read scenario file \(reference): \(error.localizedDescription)")
            }
        } else {
            throw HarnessError(description: "unknown scenario \"\(reference)\"; built-in: \(builtInScenarios.keys.sorted().joined(separator: ", ")), or a path ending in .json")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HarnessError(description: "scenario is not a JSON object")
        }
        if let extra = Set(root.keys).subtracting(["name", "steps"]).first { throw HarnessError(description: "unknown scenario key \"\(extra)\"") }
        guard let name = root["name"] as? String, !name.isEmpty else { throw HarnessError(description: "scenario needs a non-empty \"name\"") }
        guard let raw = root["steps"] as? [Any], !raw.isEmpty, raw.count <= 99 else { throw HarnessError(description: "scenario needs 1-99 \"steps\"") }
        var steps: [Step] = []
        for (index, element) in raw.enumerated() {
            let position = "step \(index + 1)"
            guard var params = element as? [String: Any], let action = params.removeValue(forKey: "action") as? String else {
                throw HarnessError(description: "\(position): needs an \"action\" string")
            }
            guard let spec = actions[action] else {
                throw HarnessError(description: "\(position): unknown action \"\(action)\"; known: \(actions.keys.sorted().joined(separator: ", "))")
            }
            let label = (params.removeValue(forKey: "label") as? String) ?? action
            guard label.range(of: "^[a-z0-9][a-z0-9-]{0,39}$", options: .regularExpression) != nil else {
                throw HarnessError(description: "\(position): label must match [a-z0-9][a-z0-9-]{0,39}")
            }
            if let extra = Set(params.keys).subtracting(spec.keys).first {
                throw HarnessError(description: "\(position) (\(action)): unknown key \"\(extra)\"; allowed: \(spec.keys.sorted())")
            }
            let step = Step(action: action, label: label, params: params)
            try spec.validate(Context(step: step, model: nil, plan: nil))
            if action == "quit", index != raw.count - 1 { throw HarnessError(description: "\(position): quit must be the last step") }
            steps.append(step)
        }
        return (name, steps)
    }

    /// Never overwrites anything the runner did not write. Refuses system/preference locations.
    static func checkOutput(_ path: String) throws -> URL {
        let url = resolvedOutputURL(URL(fileURLWithPath: path).standardizedFileURL)
        if isProtected(url.path) { throw HarnessError(description: "--qa-output \(url.path) is a protected location") }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return url }
        guard isDirectory.boolValue else { throw HarnessError(description: "--qa-output \(url.path) exists and is not a directory") }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        try validate(names.map { name -> (name: String, kind: QAOutputDirectory.Kind) in
            var info = stat()
            let regular = lstat(url.appendingPathComponent(name).path, &info) == 0 && QAOutputDirectory.isRegularOutput(info)
            return (name, regular ? .regular : .other)
        }, path: url.path)
        return url
    }

    /// realpath(3) of the deepest existing ancestor plus the components still to be created.
    /// (Foundation's resolvingSymlinksInPath leaves missing paths alone and maps /private/var,
    /// /private/tmp back to their symlinked forms, which the output walk refuses.)
    static func resolvedOutputURL(_ url: URL) -> URL {
        var existing = url, missing: [String] = []
        var resolved: UnsafeMutablePointer<CChar>?
        while true {
            resolved = realpath(existing.path, nil)
            if resolved != nil || existing.path == "/" { break }
            missing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        defer { free(resolved) }
        let base = resolved.map { URL(fileURLWithPath: String(cString: $0)) } ?? existing
        return missing.reduce(base) { $0.appendingPathComponent($1) }
    }

    static func isProtected(_ path: String) -> Bool {
        let home = resolvedOutputURL(FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL).path
        let forbidden = [home + "/Library", "/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/etc", "/private/etc",
                         "/private/var/root", resolvedOutputURL(Bundle.main.bundleURL).path]
        return path == "/" || path == home || forbidden.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Empty, or the marker plus runner files only, each a single-link regular file.
    static func validate(_ entries: [(name: String, kind: QAOutputDirectory.Kind)], path: String) throws {
        guard !entries.isEmpty else { return }
        guard entries.contains(where: { $0.name == markerName }) else {
            throw HarnessError(description: "--qa-output \(path) is not empty and was not created by this runner (no \(markerName))")
        }
        for entry in entries {
            guard entry.name == markerName || isRunnerFile(entry.name) else {
                throw HarnessError(description: "--qa-output contains a file this runner did not write: \(entry.name)")
            }
            guard entry.kind == .regular else {
                throw HarnessError(description: "--qa-output entry \(entry.name) is not a single-link regular file (hard link, symlink, directory or other); refusing")
            }
        }
    }

    static func isRunnerFile(_ name: String) -> Bool {
        name == "runner.json" || name.range(of: "^step-[0-9]{2}-[a-z0-9-]+\\.(json|png)$", options: .regularExpression) != nil
    }

    // MARK: Run

    static func run(_ plan: Plan, model: AppModel) async {
        do {
            _ = try await execute(plan, model: model)
            NSApp.terminate(nil)
        } catch {
            FileHandle.standardError.write(Data("GitHubPet QA runner: harness error: \(error)\n".utf8))
            model.cleanupScopeSimulation()
            exit(1)
        }
    }

    /// Runs every step and writes the records; returns the runner.json summary. Never terminates.
    static func execute(_ plan: Plan, model: AppModel) async throws -> [String: Any] {
        // From here on, all output goes through one O_NOFOLLOW directory descriptor; entries are
        // validated again through it, since the path may have changed since preflight.
        let out: QAOutputDirectory
        do { out = try QAOutputDirectory(plan.output) } catch { throw HarnessError(description: "--qa-output: \(error)") }
        // Belt and braces: the descriptor's real location must still be outside protected paths.
        guard let real = out.resolvedPath, !isProtected(real) else {
            throw HarnessError(description: "--qa-output resolved to a protected or unknown location")
        }
        let existing = try out.entries()
        try validate(existing, path: plan.output.path)
        for entry in existing where isRunnerFile(entry.name) { try out.removeRegularFile(entry.name) }
        try out.write(Data("GitHub Pet QA scenario runner output. Only runner files may live here.\n".utf8), name: markerName)
        var summary: [String: Any] = ["scenario": plan.name, "defaultsDomain": model.simulationDomain ?? NSNull(),
                                      "steps": plan.steps.count, "verdict": "none: QA judges the step records"]
        try await settle(model, plan)
        try await record(index: 0, step: Step(action: "launch", label: "launch", params: [:]), plan: plan, model: model,
                         out: out, context: Context(step: Step(action: "launch", label: "launch", params: [:]), model: model, plan: plan))
        for (offset, step) in plan.steps.enumerated() {
            let context = Context(step: step, model: model, plan: plan)
            context.output = out
            context.index = offset + 1
            let spec = actions[step.action]!
            try await spec.perform(context)
            if step.action == "quit" {
                summary["quit"] = context.notes
                break
            }
            try await settle(model, plan)
            model.tick()
            try await record(index: offset + 1, step: step, plan: plan, model: model, out: out, context: context)
        }
        summary["completed"] = true
        try write(summary, name: "runner.json", to: out)
        return summary
    }

    /// Waits until every launched simulated request was received by the model or is held.
    static func settle(_ model: AppModel, _ plan: Plan) async throws {
        let end = ContinuousClock.now.advanced(by: plan.settleLimit)
        while !model.simulatedScopeQuiescent {
            guard ContinuousClock.now < end else { throw HarnessError(description: "simulated requests did not settle within \(plan.settleLimit)") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await Task.yield()
    }

    // MARK: Actions

    final class Context {
        let step: Step
        let model: AppModel!
        let plan: Plan?
        var renders: [String] = []
        var pngs: [String] = []
        var notes: [String: Any] = [:]
        var output: QAOutputDirectory?
        var index = 0
        init(step: Step, model: AppModel?, plan: Plan?) { self.step = step; self.model = model; self.plan = plan }

        func string(_ key: String, _ allowed: [String], default fallback: String? = nil) throws -> String {
            guard let value = step.params[key] as? String ?? fallback else { throw HarnessError(description: "\(step.action): \"\(key)\" is required, one of \(allowed)") }
            guard allowed.contains(value) else { throw HarnessError(description: "\(step.action): \"\(key)\" must be one of \(allowed)") }
            return value
        }
        func bool(_ key: String) throws -> Bool {
            // Only JSON true/false: 1 and 0 also bridge to Bool through NSNumber.
            guard let number = step.params[key] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                throw HarnessError(description: "\(step.action): \"\(key)\" must be true or false")
            }
            return number.boolValue
        }
        func number(_ key: String, _ range: ClosedRange<Double>, default fallback: Double? = nil) throws -> Double {
            // JSON true/false also bridge to NSNumber; only real numbers are accepted.
            let raw = step.params[key] as? NSNumber
            let isBoolean = raw.map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
            guard !isBoolean, let value = raw?.doubleValue ?? (step.params[key] == nil ? fallback : nil) else {
                throw HarnessError(description: "\(step.action): \"\(key)\" must be a number in \(range)")
            }
            guard range.contains(value) else { throw HarnessError(description: "\(step.action): \"\(key)\" must be in \(range)") }
            return value
        }
        func account() throws -> ScopeAccount {
            try string("account", ["A", "B"], default: "A") == "A" ? ScopeSimulation.accountA : ScopeSimulation.accountB
        }
    }

    struct Action {
        var keys: Set<String> = []
        /// Parameter validation only; runs at load time with no model.
        var validate: (Context) throws -> Void = { _ in }
        var perform: @MainActor (Context) async throws -> Void
    }

    /// Every action calls what the matching user control calls (Simulated scope menu, Inbox
    /// buttons, Settings toggles/picker). PR B adds its Settings draft/discovery actions here.
    static let actions: [String: Action] = coreActions.merging(settingsActions) { core, _ in core }
    static let coreActions: [String: Action] = [
        "capture": Action { _ in },
        "account": Action(keys: ["account"], validate: { _ = try $0.account() }) { c in
            c.model.simulateScopeAccount(try c.account() == ScopeSimulation.accountB)
        },
        "apply": Action(keys: ["scope"], validate: { _ = try $0.string("scope", ["selected", "everything"]) }) { c in
            c.model.simulateScopeApply(try c.string("scope", ["selected", "everything"]) == "selected")
        },
        "hold": Action(keys: ["count", "refresh"], validate: { c in
            _ = try c.number("count", 1...8, default: 1)
            if c.step.params["refresh"] != nil { _ = try c.bool("refresh") }
        }) { c in
            let refresh = c.step.params["refresh"] == nil ? true : try c.bool("refresh")
            c.model.simulateScopeHold(Int(try c.number("count", 1...8, default: 1)), refresh: refresh)
        },
        "deliver-oldest": Action { c in c.model.simulateScopeDeliverOne(newest: false) },
        "deliver-newest": Action { c in c.model.simulateScopeDeliverOne(newest: true) },
        "deliver-all": Action { c in c.model.simulateScopeDeliver() },
        "inject-row": Action { c in c.model.simulateScopeInject() },
        "inject-incident": Action(keys: ["tier"], validate: { _ = try $0.string("tier", ["minor", "major"]) }) { c in
            c.model.injectServiceIncident(try c.string("tier", ["minor", "major"]) == "major" ? .major : .minor)
        },
        "resolve-incidents": Action { c in c.model.resolveServiceIncidents() },
        "partial": Action(keys: ["on"], validate: { _ = try $0.bool("on") }) { c in c.model.simulateScopePartial(try c.bool("on")) },
        "reload": Action(keys: ["viewer", "account"], validate: { c in
            _ = try c.string("viewer", ["known", "unknown"]); _ = try c.account()
        }) { c in
            c.model.simulateScopeReload(forgetViewer: try c.string("viewer", ["known", "unknown"]) == "unknown", account: try c.account())
        },
        "corrupt": Action(keys: ["account"], validate: { _ = try $0.account() }) { c in c.model.simulateScopeCorrupt(try c.account()) },
        "corrupt-reload": Action { c in c.model.simulateScopeReload(corrupt: true) },
        "seed": Action { c in c.model.simulateScopeSeed() },
        "repair": Action { c in c.model.simulateScopeRepair() },
        "privacy": Action(keys: ["on"], validate: { _ = try $0.bool("on") }) { c in c.model.settings.privacyMode = try c.bool("on") },
        "show-details": Action(keys: ["on"], validate: { _ = try $0.bool("on") }) { c in
            // The Inbox "Show details" link exists only while privacy mode is on.
            if c.model.settings.privacyMode { c.model.detailsRevealed = try c.bool("on") }
        },
        "reduce-motion": Action(keys: ["on"], validate: { _ = try $0.bool("on") }) { c in c.model.settings.reducedMotion = try c.bool("on") },
        "refresh": Action { c in c.model.refresh() },
        "mark-seen": Action { c in c.model.markAllSeen() },
        "source": Action(keys: ["source"], validate: { _ = try $0.string("source", ["fixtures", "gh"]) }) { c in
            c.model.settings.dataSource = try c.string("source", ["fixtures", "gh"]) == "gh" ? .githubCLI : .fixtures
        },
        "clock-set": Action(keys: ["time"], validate: { c in
            guard let text = c.step.params["time"] as? String, ISO8601DateFormatter().date(from: text) != nil else {
                throw HarnessError(description: "clock-set: \"time\" must be ISO 8601, e.g. 2026-11-15T12:00:00Z")
            }
        }) { c in c.plan!.clock.set(ISO8601DateFormatter().date(from: c.step.params["time"] as! String)!) },
        "clock-advance": Action(keys: ["seconds"], validate: { _ = try $0.number("seconds", 0...86_400) }) { c in
            c.plan!.clock.advance(try c.number("seconds", 0...86_400))
        },
        "wait-real": Action(keys: ["seconds"], validate: { _ = try $0.number("seconds", 0...60) }) { c in
            try await Task.sleep(nanoseconds: UInt64(try c.number("seconds", 0...60) * 1e9))
        },
        "open-settings": Action { c in
            guard c.plan!.rendersPNGs, let out = c.output else { return }
            try await renderPNG(SettingsView(model: c.model), name: stem(c) + "-settings", out: out, asWindow: true, into: c)
        },
        "quit": Action { c in
            // Normal-quit path with replies possibly still held; then prove no late callback revives the domain.
            let model = c.model!, held = model.simulatedHeldReplies, received = model.receivedScopeReplies
            let domain = model.simulationDomain
            model.cleanupScopeSimulation()
            try await settle(model, c.plan!)
            c.notes = ["heldAtQuit": held, "lateRepliesReceivedAfterCleanup": model.receivedScopeReplies - received,
                       "discardedTotal": model.discardedScopeReplies,
                       // The domain is in-memory only; the plist check confirms nothing was ever written.
                       "domainKeysAfterCleanup": model.simulationDomainKeyCount,
                       "plistOnDisk": domain.map { FileManager.default.fileExists(atPath: FileManager.default
                           .homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\($0).plist").path) } ?? false]
        },
    ]

    static func stem(_ c: Context) -> String { String(format: "step-%02d-", c.index) + c.step.label }

    /// Renders into a private scratch directory, then copies a decoded-and-checked PNG into the
    /// output through the descriptor. A missing or invalid image is a harness error.
    static func renderPNG<V: View>(_ view: V, name: String, out: QAOutputDirectory, asWindow: Bool = false,
                                   into context: Context) async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("github-pet-qa-render-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        context.renders += await SnapshotRenderer.render(view, name: name, directory: scratch, appearance: .aqua, asWindow: asWindow)
        let png: Data
        do { png = try QAOutputDirectory.validatedPNG(try? Data(contentsOf: scratch.appendingPathComponent(name + ".png"))) } catch {
            throw HarnessError(description: "\(name).png: \(error)")
        }
        try out.write(png, name: name + ".png")
        context.pngs.append(name + ".png")
    }

    // MARK: Records

    static func record(index: Int, step: Step, plan: Plan, model: AppModel, out: QAOutputDirectory, context: Context) async throws {
        let stem = String(format: "step-%02d-", index) + step.label
        if plan.rendersPNGs {
            try await renderPNG(InboxView(model: model, showsWindowButton: false, marksSeenOnClose: false),
                                name: stem + "-inbox", out: out, asWindow: true, into: context)
            let panel = model.layout(model.settings.mascotSize).panelSize
            // Rendered at the scenario clock, so the pose/clip/burst phase matches this record.
            try await renderPNG(MascotView(model: model, renderDate: model.clock()).frame(width: panel.width, height: panel.height),
                                name: stem + "-mascot", out: out, into: context)
        }
        var state = snapshot(model, clock: plan.clock)
        state["step"] = index
        state["label"] = step.label
        state["action"] = step.action
        state["params"] = step.params
        state["renders"] = context.renders
        state["pngs"] = context.pngs.sorted()
        state["mascotRenderedAt"] = ISO8601DateFormatter().string(from: model.clock())
        try write(state, name: stem + ".json", to: out)
    }

    /// What the user would see, read from the same model properties the views render.
    static func snapshot(_ model: AppModel, clock: QAScenarioClock) -> [String: Any] {
        func iso(_ date: Date?) -> Any { date.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull() }
        func optional(_ value: Any?) -> Any { value ?? NSNull() }
        func account(_ value: ScopeAccount?) -> Any {
            value == nil ? NSNull() : value == ScopeSimulation.accountA ? "A" : value == ScopeSimulation.accountB ? "B" : "other"
        }
        let privacy = model.inboxPrivacy
        let rows: [[String: Any]] = model.items.map { item in
            ["id": item.id, "repository": item.repository, "unseen": model.isUnseen(item), "isDemo": item.isDemo,
             "visibleTitle": PrivacyText.title(item, privacy: privacy), "visibleSubtitle": PrivacyText.subtitle(item, privacy: privacy)]
        }
        let identity: Any = model.monitoringScopeIdentity.map { identity -> Any in
            if identity == .demo { return "demo" }
            if identity == .github(ScopeSimulation.accountA) { return "github:A" }
            if identity == .github(ScopeSimulation.accountB) { return "github:B" }
            return "github:other"
        } ?? NSNull()
        let scope: Any = model.activeMonitoringScope.map { $0.mode == .everything ? "Everything" : "Selected" } ?? NSNull()
        return [
            "scenarioClock": iso(clock.now()),
            "defaultsDomain": optional(model.simulationDomain),
            "simulatedAccount": optional(model.simulatedAccountName),
            "settings": ["dataSource": model.settings.dataSource == .githubCLI ? "gh" : "fixtures",
                         "privacyMode": model.settings.privacyMode, "detailsRevealed": model.detailsRevealed,
                         "reducedMotion": model.settings.reducedMotion, "effectiveReducedMotion": model.effectiveReducedMotion,
                         "alertsAllowed": model.alertsAllowed],
            "inbox": ["demoLabel": model.isDemo, "simulatedLabel": model.simulatesScope,
                      "demoNotice": optional(model.demoNotice), "hoverLines": model.hoverLines(compact: false),
                      "scopeHeader": model.scopeSummary, "scopeQuality": optional(model.scopeQuality),
                      "status": model.dataState.statusText, "hint": optional(model.dataState.hint),
                      "badge": optional(model.badge), "lastSuccess": iso(model.lastSuccess),
                      "showingLastKnown": !model.items.isEmpty && (!model.dataState.hasUsableItems || model.dataState == .stale),
                      "rows": rows],
            "attention": ["unseenCount": model.unseenCount, "showsAlertIcon": model.showsAlertIcon,
                          "mascotState": model.mascotState.rawValue,
                          "activeClip": model.activeClip.map { ["origin": $0.origin == .repository ? "repository" : "serviceIncident",
                                                                "state": $0.state.rawValue, "startedAt": iso($0.startedAt),
                                                                "endsAt": iso($0.endsAt)] as [String: Any] } ?? NSNull(),
                          "markerBurst": model.markerBurst.map { ["start": iso($0.start), "fromTier": optional($0.fromTier?.rawValue)] as [String: Any] } ?? NSNull(),
                          "incidentMarker": optional(model.incidentMarker?.tier.rawValue)],
            "service": ["status": model.serviceState.statusText(count: model.serviceIncidents.count),
                        "incidents": model.serviceIncidents.count, "unseenIncidents": model.unseenIncidents.count],
            "monitoringScope": ["identity": identity, "generation": model.monitoringScopeGeneration, "active": scope],
            "settingsScope": settingsSnapshot(model),
            "scopeSimulation": ["status": model.scopeSimulationStatus, "held": model.simulatedHeldReplies,
                                "received": model.receivedScopeReplies, "discarded": model.discardedScopeReplies,
                                "requests": model.simulatedPollLog.map { request -> [String: Any] in
                                    ["generation": request.generation, "serial": request.serial,
                                     "scope": request.identityOnly ? "IdentityOnly" : request.scope.mode == .everything ? "Everything" : "Selected",
                                     "identityOnly": request.identityOnly,
                                     // What GitHub was asked for: identity-only requests run no searches.
                                     "searchAliases": request.identityOnly ? [] : ((try? ScopeQueryPlan(scope: request.scope,
                                         expectedAccount: request.expectedAccount))?.searches.map(\.alias) ?? []),
                                     "targets": request.scope.targets.map { target in target.name.map { "\(target.owner)/\($0)" } ?? target.owner },
                                     "expectedAccount": account(request.expectedAccount)]
                                }],
        ]
    }

    static func write(_ object: [String: Any], name: String, to out: QAOutputDirectory) throws {
        try out.write(try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]), name: name)
    }

    // MARK: Built-in PR A scenarios (docs/monitoring-scope-application.md)

    static let builtInScenarios: [String: String] = coreScenarios.merging(settingsScenarios) { core, _ in core }
    static let coreScenarios: [String: String] = [
        "restore-before-display": #"""
        {"name": "restore-before-display", "steps": [
          {"action": "reload", "viewer": "unknown", "label": "reload-unknown-viewer"},
          {"action": "reload", "viewer": "known", "label": "reload-known-viewer"}]}
        """#,
        "account-a-b-a": #"""
        {"name": "account-a-b-a", "steps": [
          {"action": "account", "account": "B", "label": "switch-to-b"},
          {"action": "account", "account": "A", "label": "back-to-a"}]}
        """#,
        "stale-reply-after-apply": #"""
        {"name": "stale-reply-after-apply", "steps": [
          {"action": "hold", "label": "hold-one"},
          {"action": "apply", "scope": "everything", "label": "apply-everything"},
          {"action": "inject-row", "label": "inject-new-row"},
          {"action": "deliver-oldest", "label": "deliver-stale-reply"},
          {"action": "refresh", "label": "refresh-unchanged"}]}
        """#,
        "corrupt-saved-selected": #"""
        {"name": "corrupt-saved-selected", "steps": [
          {"action": "corrupt-reload", "label": "corrupt-a-and-reload"},
          {"action": "refresh", "label": "refresh-identity-only"},
          {"action": "account", "account": "B", "label": "switch-to-b-while-a-corrupt"},
          {"action": "account", "account": "A", "label": "back-to-corrupt-a"},
          {"action": "reload", "viewer": "unknown", "label": "unknown-viewer-resolves-corrupt"},
          {"action": "repair", "label": "repair-selections"}]}
        """#,
        "partial-recovery-new-once": #"""
        {"name": "partial-recovery-new-once", "steps": [
          {"action": "partial", "on": true, "label": "partial-replies"},
          {"action": "inject-row", "label": "inject-while-partial"},
          {"action": "partial", "on": false, "label": "recover-silently"},
          {"action": "inject-row", "label": "inject-new-once"},
          {"action": "refresh", "label": "refresh-no-replay"}]}
        """#,
        "incidents-preserved": #"""
        {"name": "incidents-preserved", "steps": [
          {"action": "inject-incident", "tier": "major", "label": "major-incident"},
          {"action": "apply", "scope": "everything", "label": "apply-everything"},
          {"action": "clock-advance", "seconds": 1, "label": "one-second-later"},
          {"action": "apply", "scope": "selected", "label": "apply-selected"},
          {"action": "clock-advance", "seconds": 5, "label": "clip-expired"}]}
        """#,
        "privacy-summary": #"""
        {"name": "privacy-summary", "steps": [
          {"action": "privacy", "on": true, "label": "privacy-on"},
          {"action": "apply", "scope": "everything", "label": "apply-everything"},
          {"action": "show-details", "on": true, "label": "show-details"},
          {"action": "show-details", "on": false, "label": "hide-details"},
          {"action": "account", "account": "B", "label": "account-b-private"},
          {"action": "privacy", "on": false, "label": "privacy-off"},
          {"action": "open-settings", "label": "settings"}]}
        """#,
        "demo-isolation": #"""
        {"name": "demo-isolation", "steps": [
          {"action": "hold", "label": "hold-one"},
          {"action": "source", "source": "fixtures", "label": "switch-to-fixtures"},
          {"action": "deliver-all", "label": "deliver-into-demo"},
          {"action": "apply", "scope": "everything", "label": "apply-ignored-in-fixtures"},
          {"action": "source", "source": "gh", "label": "back-to-simulated-gh"},
          {"action": "hold", "label": "hold-before-quit"},
          {"action": "quit", "label": "quit-with-held-reply"}]}
        """#,
    ]
}

/// App clock for runner launches only. Starts at a fixed instant so repeated runs match.
final class QAScenarioClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ISO8601DateFormatter().date(from: "2026-11-15T12:00:00Z")!
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return instant }
    func set(_ date: Date) { lock.lock(); instant = date; lock.unlock() }
    func advance(_ seconds: TimeInterval) { lock.lock(); instant.addTimeInterval(seconds); lock.unlock() }
}
