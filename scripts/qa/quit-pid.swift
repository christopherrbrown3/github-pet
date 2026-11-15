// Ask one specific process to quit normally (the same quit Apple Event as Cmd-Q), so the
// app's own applicationWillTerminate cleanup runs. Targets a PID, never a bundle ID: the
// user's saved GitHubPet build shares the bundle ID and must not be quit.
import AppKit

guard CommandLine.arguments.count == 2, let pid = pid_t(CommandLine.arguments[1]),
      let app = NSRunningApplication(processIdentifier: pid) else {
    FileHandle.standardError.write("usage: quit-pid <pid of a running app>\n".data(using: .utf8)!)
    exit(64)
}
exit(app.terminate() ? 0 : 1)
