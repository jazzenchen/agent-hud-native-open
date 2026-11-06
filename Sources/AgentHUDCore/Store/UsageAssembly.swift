import Foundation

/// What every host builds at launch the same way: the settings, then the store that collects into them, with the
/// restart copy of the last report on screen from the start.
@MainActor
public enum UsageAssembly {
    /// The settings kept in `defaults`, starting from `defaultAgents` when there are none, with `language` saved to them
    /// when given; the interface takes their language.
    public static func settings(defaults: UserDefaults = .standard, defaultAgents: [AgentDescriptor] = [],
                                language: AppLanguage? = nil) -> SettingsStore {
        let settings = SettingsStore(defaults: defaults, defaultAgents: defaultAgents)
        if let language { settings.update { $0.language = language } }
        L10n.setLanguage(settings.settings.language)
        return settings
    }

    /// The store: with `ledger`, over the installed clients (`CombinedUsageProvider.standard`) behind the restart copy in
    /// the data directory, which it shows at once, and reading a turn's calls from `ledger`; without one, over the sample
    /// data (`DemoUsageProvider`) and its turns' calls, on the demo's clock, with no restart copy. `hooks` are the host's collection hooks.
    public static func store(settings: SettingsStore, ledger: UsageLedger?,
                             hooks: UsageCollectionHooks = UsageCollectionHooks()) -> UsageStore {
        let provider: any UsageProvider = ledger.map { CombinedUsageProvider.standard(settings: settings, ledger: $0) } ?? DemoUsageProvider()
        let retained = RetainedUsageProvider(provider: provider,
                                             cacheURL: ledger == nil ? nil : AppSupport.directory.appendingPathComponent("last-usage-report.json"))
        let store = ledger == nil ? UsageStore(provider: retained, settings: settings, hooks: hooks, clock: { DemoClock.now })
            : UsageStore(provider: retained, settings: settings, hooks: hooks, updatesModelPrices: true)
        store.ledger = ledger
        if ledger == nil { store.sampleTurnCalls = { DemoData.turnCalls(session: $0.id, turn: $1) } }
        if let report = retained.initialReport { store.replace(report: report) }
        return store
    }
}
