import AppKit
@testable import GitHubPet
@testable import GitHubPetCore

@main struct EdgeCasesQA {
    @MainActor static func main() async {
        if CommandLine.arguments.contains("transparent") {
            let art = ArtProfile(canvas: 256, rows: Array(repeating: nil, count: 256))
            let placement = HoverPlacement.place(art: art, layout: MascotLayout(artSide: 128),
                popover: CGSize(width: 160, height: 80), panelOrigin: CGPoint(x: 300, y: 200),
                screen: CGRect(x: 0, y: 0, width: 1440, height: 900))
            print("transparent finite=\(placement.arrowGap.isFinite) meetsTarget=\(placement.meetsTarget)")
            fflush(stdout)
            MascotWindowController.reportIfUnclear(placement)
            print("PASS diagnostic returned without trap")
            return
        }
        _ = NSApplication.shared
        let suite = "dev.github-pet.qa.edge.\(ProcessInfo.processInfo.processIdentifier)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        var options = LaunchOptions()
        options.defaultsSuite = suite
        options.snapshotDirectory = URL(fileURLWithPath: "/tmp/qa42-no-render")
        options.forcePlaceholder = true
        let model = AppModel(options: options)
        model.settings.reducedMotion = true
        model.settings.mascotVisible = false
        let screen = NSScreen.main!.visibleFrame
        let size = model.layout(128).panelSize
        model.settings.mascotOriginX = screen.maxX - size.width
        model.settings.mascotOriginY = screen.minY + min(200, screen.height / 3)
        let controller = MascotWindowController(model: model)
        model.settings.mascotVisible = true
        try? await Task.sleep(nanoseconds: 100_000_000)
        let container = controller.panelContentView as! MascotContainerView
        var failures = 0
        // Simulate only the drag's window movement and release callback; never moves OS pointer.
        func drop(_ name: String, at origin: CGPoint) {
            container.window!.setFrameOrigin(origin)
            container.onDragEnded?(origin)
            let shown = controller.panelFrame!
            let saved = CGPoint(x: model.settings.mascotOriginX!, y: model.settings.mascotOriginY!)
            let inside = NSScreen.screens.contains { $0.visibleFrame.insetBy(dx: -0.5, dy: -0.5).contains(shown) }
            let pass = inside && shown.origin == saved
            print("\(pass ? "PASS" : "FAIL") \(name) inside=\(inside) saved-equals-shown=\(saved == shown.origin) shown=\(shown.origin) saved=\(saved)")
            if !pass { failures += 1 }
        }
        let initial = controller.panelFrame!.origin
        drop("already-saved edge drop", at: CGPoint(x: initial.x + size.width * 0.4, y: initial.y))
        let union = NSScreen.screens.map(\.visibleFrame).reduce(CGRect.null) { $0.union($1) }
        drop("off-all-displays fallback", at: CGPoint(x: union.maxX + size.width * 2, y: union.maxY + size.height * 2))
        model.settings.mascotVisible = false
        print("RESULT failures=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
