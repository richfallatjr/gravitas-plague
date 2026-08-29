import Foundation

nonisolated enum TuringRuntimeLipSyncProductionDependencies {
    static func makeGenerator(
        bundle: Bundle = .main
    ) -> any TuringRuntimeLipSyncManifestGenerating {
        TuringPocketSphinxRuntimeLipSyncGenerator(
            resourceLocator: TuringRuntimeLipSyncResourceLocator(bundle: bundle),
            configuration: .production
        )
    }

    static func makeAnalysisCoordinator(
        bundle: Bundle = .main
    ) -> TuringGeneratedSpeechAnalysisCoordinator {
        TuringGeneratedSpeechAnalysisCoordinator(
            primaryGenerator: makeGenerator(bundle: bundle),
            compatibilityAnalyzer: TuringGeneratedSpeechAnalyzer(),
            policy: .production,
            eventHub: .shared
        )
    }

    static let productionPrimaryGeneratorID = "pocketsphinx-forced-align"
}
