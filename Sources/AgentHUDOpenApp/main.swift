#if os(Windows)
import AgentHUDCore
import Foundation

// Hooks and adapter commands run as short-lived processes, without the interface or an account query.
if let status = HookEntry.handle(arguments: CommandLine.arguments) { exit(status) }

// The interface is macOS-only for now; the Windows executable answers the read-only commands from the same sources.
if CommandLine.arguments.contains("--probe-open-agents") {
    Task { print(await OpenAgentDiagnostics.localSummary()); exit(0) }
    dispatchMain()
} else {
    let settings = UsageAssembly.settings()
    Task {
        let status = await UsageProbe.run(settings: settings)
        exit(status)
    }
    dispatchMain()
}
#else
import AppKit
import AgentHUDCore
import AgentHUDDesktop

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var desktop: DesktopApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let options = DesktopLaunchOptions.parse(CommandLine.arguments)
        if let directory = options.snapshotDirectory {
            Task { @MainActor in
                await SnapshotRunner.run(language: options.language, into: directory)
                NSApp.terminate(nil)
            }
            return
        }
        // Only one Agent HUD runs at a time, since the one that runs points the clients' hooks at itself: a launch while
        // another copy runs says where it is and quits before reading or writing anything. A probe reads and quits, and
        // a demo keeps its own preferences, has no ledger or report cache, installs no hooks and serves no approvals, so
        // either may run beside the real one, unless it is told to reset the preferences, which that one uses.
        if options.resetDefaults || (!options.probe && !options.demo), !SingleInstance.claim() {
            NSApp.terminate(nil)
            return
        }
        let demoSuite = "app.agenthud.open.demo"
        if options.resetDefaults {
            // The demo keeps its own suite, so resetting has to clear that too or a stale demo survives it.
            UserDefaults.standard.removePersistentDomain(forName: demoSuite)
            if let bundleID = Bundle.main.bundleIdentifier {
                UserDefaults.standard.removePersistentDomain(forName: bundleID)
            }
        }
        let settings = UsageAssembly.settings(defaults: options.demo ? UserDefaults(suiteName: demoSuite)! : .standard,
                                              defaultAgents: options.demo ? DemoData.everyAgent : [], language: options.language)
        if options.probe {
            Task { @MainActor in exit(await UsageProbe.run(settings: settings)) }
            return
        }
        // A demo saved before the sample changed holds rows the sample no longer reads; it starts over from the sample's,
        // keeping every other preference.
        if options.demo, !settings.agents.contains(where: { row in DemoData.agents.contains { $0.id == row.id } }) {
            settings.updateAgents { _ in DemoData.everyAgent }
        }
        let store = UsageAssembly.store(settings: settings, ledger: options.demo ? nil : .open())
        if !options.demo, let executable = Bundle.main.executableURL {
            SessionObservers.configure(executable: executable, enabled: settings.settings.clientHooks)
        }
        let desktop = DesktopApplication(options: options, settings: settings, store: store)
        self.desktop = desktop
        desktop.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { desktop?.stop() }
}

// Hooks and adapter commands run as short-lived processes, without the interface or an account query.
if let status = HookEntry.handle(arguments: CommandLine.arguments) { exit(status) }

if CommandLine.arguments.contains("--probe-open-agents") {
    Task { print(await OpenAgentDiagnostics.localSummary()); exit(0) }
    dispatchMain()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
#endif
