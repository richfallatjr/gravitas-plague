import Foundation
import MLX

public struct TuringQwenNativeBaseClonePreflightReport: Sendable {
    public let voiceID: String
    public let variantID: String
    public let modelID: String
    public let ttsModelType: String
    public let quantizationBits: Int
    public let targetTokenCount: Int
    public let refTextTokenCount: Int
    public let referenceRowCount: Int
    public let originalReferenceRowCount: Int
    public let referenceWindowStrategy: String
    public let codebookCount: Int
    public let speakerEmbeddingCount: Int
    public let languageCodecID: Int
    public let xVectorOnlyMode: Bool

    public init(
        voiceID: String,
        variantID: String,
        modelID: String,
        ttsModelType: String,
        quantizationBits: Int,
        targetTokenCount: Int,
        refTextTokenCount: Int,
        referenceRowCount: Int,
        originalReferenceRowCount: Int,
        referenceWindowStrategy: String,
        codebookCount: Int,
        speakerEmbeddingCount: Int,
        languageCodecID: Int,
        xVectorOnlyMode: Bool
    ) {
        self.voiceID = voiceID
        self.variantID = variantID
        self.modelID = modelID
        self.ttsModelType = ttsModelType
        self.quantizationBits = quantizationBits
        self.targetTokenCount = targetTokenCount
        self.refTextTokenCount = refTextTokenCount
        self.referenceRowCount = referenceRowCount
        self.originalReferenceRowCount = originalReferenceRowCount
        self.referenceWindowStrategy = referenceWindowStrategy
        self.codebookCount = codebookCount
        self.speakerEmbeddingCount = speakerEmbeddingCount
        self.languageCodecID = languageCodecID
        self.xVectorOnlyMode = xVectorOnlyMode
    }
}

public actor TuringQwenNativeBaseCloneEngine {
    private static let decodeReferenceContextRows = 24

    private let modelRoot: URL
    private let trace: TuringQwenNativeTrace
    private let weightBackend: TuringQwenNativeWeightBackend
    private let config: TuringQwenNativeConfig
    private let sharedResidentResources: TuringQwenNativeResidentResources?
    private var residentWeights: TuringQwenNativeResidentResources?
    private var staticPromptContexts: [StaticPromptContextKey: TuringQwenNativeBaseCloneStaticPromptContext] = [:]

    public init(
        modelRoot: URL,
        weightBackend: TuringQwenNativeWeightBackend = .baseCloneRuntime,
        trace: TuringQwenNativeTrace = .stdout(prefix: "[TuringQwenNativeBaseClone]")
    ) throws {
        self.modelRoot = modelRoot
        self.trace = trace
        self.weightBackend = weightBackend
        self.sharedResidentResources = nil

        try Self.preflightModelRoot(modelRoot)
        let loadedConfig = try TuringQwenNativeConfig.load(from: modelRoot)
        try loadedConfig.validateBaseCloneRuntime()
        self.config = loadedConfig
        try TuringQwenNativeQuantizedLinear(
            tensorPrefix: "model",
            backend: weightBackend.kind,
            groupSize: loadedConfig.quantization?.groupSize ?? 64,
            bits: loadedConfig.quantization?.bits ?? 4
        )
        .preflightOnly()
    }

    public init(
        modelRoot: URL,
        residentResources: TuringQwenNativeResidentResources,
        trace: TuringQwenNativeTrace = .stdout(prefix: "[TuringQwenNativeBaseClone]")
    ) throws {
        self.modelRoot = modelRoot
        self.trace = trace
        self.weightBackend = .baseCloneRuntime
        self.sharedResidentResources = residentResources

        try Self.preflightModelRoot(modelRoot)
        self.config = residentResources.config
    }

    public func generateBaseClone(
        prompt: TuringQwenNativeBaseClonePrompt
    ) async throws -> TuringQwenNativeAudio {
        TuringQwenNativeMemoryControl.configureForBaseClone(
            performanceMode: prompt.performanceMode
        )
        let renderStart = Date()
        trace.stageStarted(.fullGenerate)
        defer {
            trace.stageCompleted(.fullGenerate)
        }

        print("""
        [TuringQwenNativeBaseClone] generation requested
          voiceID: \(prompt.cloneProfile.voiceID)
          variantID: \(prompt.cloneProfile.defaultVariantID)
          targetCharacters: \(prompt.text.utf16.count)
          maxNewRows: \(prompt.maxNewRows)
          performanceMode: \(prompt.performanceMode.rawValue)
          referenceRowLimit: \(prompt.referenceRowLimit.map(String.init) ?? "full")
          referenceWindowStrategy: \(prompt.referenceWindowStrategy.rawValue)
          rawReferenceRuntime: false
          precomputedCloneArtifacts: true
        """)

        let generated = try generateCodebookForDecode(prompt)
        let generatedRows = generated.generatedRows
        let codePredictorSeconds = generated.codePredictorTotalSeconds
        let talkerOneStepTotalSeconds = generated.talkerOneStepTotalSeconds
        let referenceRows = generated.referenceRows
        let initialPromptSeconds = generated.initialPromptSeconds
        let initialTalkerForwardSeconds = generated.initialTalkerForwardSeconds

        let decodeReferenceRows = Array(referenceRows.suffix(Self.decodeReferenceContextRows))
        let rowsForDecode = decodeReferenceRows + generatedRows

        let decodeQueuedAt = Date()
        print("""
        [TuringQwenNativeBaseClone] decode queued
          referenceRows: \(referenceRows.count)
          decodeReferenceRows: \(decodeReferenceRows.count)
          generatedRows: \(generatedRows.count)
          totalRows: \(rowsForDecode.count)
          decodeFullReference: false
          trimReferenceAfterDecode: true
          decoderConcurrencyPolicy: serializedHighWatermarkStage
          qwenGenerationConcurrencyUnchanged: true
        """)

        let decodeStart = Date()
        let fullAudio = try await TuringQwenNativeSpeechDecodeGate.shared.decode(
            codebookRows: rowsForDecode,
            modelRoot: modelRoot,
            performanceMode: prompt.performanceMode,
            queuedAt: decodeQueuedAt
        )
        let decodeSeconds = Date().timeIntervalSince(decodeStart)
        let trimmedSamples = try TuringQwenNativeBaseCloneDecodeTrimmer.trimReferencePrefix(
            from: fullAudio.samples,
            referenceRowCount: decodeReferenceRows.count,
            totalRowCount: rowsForDecode.count
        )
        let audio = TuringQwenNativeAudio(
            samples: trimmedSamples,
            sampleRate: fullAudio.sampleRate
        )
        let renderSeconds = Date().timeIntervalSince(renderStart)
        let realTimeFactor = TuringQwenNativeRealtimeBudgetProbe.realTimeFactor(
            renderSeconds: renderSeconds,
            audioDurationSeconds: audio.durationSeconds
        )
        var perfTrace = TuringQwenNativePerfTrace()
        perfTrace.recordCodePredictor(
            generatedRows: generatedRows.count,
            codeGroupsPerRow: config.talkerConfig.numCodeGroups
        )
        let memoryPeak = TuringQwenNativePerfTrace.memoryPeakMegabytes()
        let averageSecondsPerRow: Double
        if generatedRows.isEmpty {
            averageSecondsPerRow = 0
        } else {
            averageSecondsPerRow = codePredictorSeconds / Double(generatedRows.count)
        }
        let codePredictorOneStepSeconds = max(0, codePredictorSeconds - perfTrace.codePredictorPrefillTotalSeconds)
        TuringQwenNativePerfTrace.log(
            TuringQwenNativePerfReport(
                presetID: prompt.cloneProfile.voiceID,
                modelID: prompt.cloneProfile.modelID,
                quantization: "\(config.quantization?.bits ?? 0)bit",
                fixtureRowsUsed: false,
                performanceMode: prompt.performanceMode.rawValue,
                generatedRows: generatedRows.count,
                generatedSamples: audio.samples.count,
                sampleRate: audio.sampleRate,
                audioDurationSeconds: audio.durationSeconds,
                totalRenderSeconds: renderSeconds,
                initialPromptSeconds: initialPromptSeconds,
                initialTalkerForwardSeconds: initialTalkerForwardSeconds,
                talkerOneStepTotalSeconds: talkerOneStepTotalSeconds,
                codePredictorPrefillTotalSeconds: perfTrace.codePredictorPrefillTotalSeconds,
                codePredictorOneStepTotalSeconds: codePredictorOneStepSeconds,
                codePredictorTotalSeconds: codePredictorSeconds,
                codePredictorPrefillCount: perfTrace.codePredictorPrefillCount,
                codePredictorOneStepCount: perfTrace.codePredictorOneStepCount,
                codePredictorNoCacheForwardCount: perfTrace.codePredictorNoCacheForwardCount,
                codePredictorKVCache: perfTrace.codePredictorKVCache,
                tokenSyncTotalSeconds: perfTrace.tokenSyncTotalSeconds,
                speechDecodeSeconds: decodeSeconds,
                playbackStartDelaySeconds: nil,
                averageSecondsPerRow: averageSecondsPerRow,
                realTimeFactor: realTimeFactor,
                mlxActiveMemoryPeakMB: memoryPeak.active,
                mlxCacheMemoryPeakMB: memoryPeak.cache,
                processFootprintPeakMB: nil
            )
        )

        print("""
        [TuringQwenNativeBaseClone] generation finished
          generatedRows: \(generatedRows.count)
          sampleRate: \(audio.sampleRate)
          sampleCount: \(audio.samples.count)
          durationSeconds: \(String(format: "%.3f", audio.durationSeconds))
          peakAbs: \(audio.peakAbs)
          rms: \(audio.rms)
          codePredictorSeconds: \(String(format: "%.3f", codePredictorSeconds))
          decodeSeconds: \(String(format: "%.3f", decodeSeconds))
          renderSeconds: \(String(format: "%.3f", renderSeconds))
          realTimeFactor: \(String(format: "%.3f", realTimeFactor))
        """)

        return audio
    }

    private func generateCodebookForDecode(
        _ prompt: TuringQwenNativeBaseClonePrompt
    ) throws -> GeneratedCodebookForDecode {
        defer {
            if sharedResidentResources == nil {
                residentWeights = nil
            }
            TuringQwenNativeMemoryControl.clearCache(
                label: "baseClone.afterCodebookBeforeDecode",
                shouldLogSnapshot: prompt.performanceMode.shouldLogMemorySnapshots
            )
            if prompt.performanceMode.shouldLogMemorySnapshots {
                print("""
                [TuringQwenNativeBaseClone] resident talker state released before decode
                  reason: codebookRowsReady
                  residentWeights: \(sharedResidentResources == nil ? "false" : "sharedWeightsRetained")
                """)
            }
        }

        let promptStart = Date()
        let prepared = try prepareBaseClonePrompt(prompt)
        let resident = try loadResidentWeights()
        let staticPromptContext = try cachedStaticPromptContext(
            prompt: prompt,
            prepared: prepared.prompt,
            resident: resident
        )
        let promptInputs = try TuringQwenNativeBaseClonePromptInputBuilder.build(
            prepared: prepared.prompt,
            config: config,
            weightsStore: resident.weightsStore,
            staticContext: staticPromptContext
        )
        let initialPromptSeconds = Date().timeIntervalSince(promptStart)

        print("""
        [TuringQwenNativeBaseClone] artifacts loaded
          refTextTokenCount: \(prepared.report.refTextTokenCount)
          referenceRows: \(prepared.report.referenceRowCount)
          originalReferenceRows: \(prepared.report.originalReferenceRowCount)
          referenceWindowStrategy: \(prepared.report.referenceWindowStrategy)
          codebookCount: \(prepared.report.codebookCount)
          speakerEmbeddingShape: [\(prepared.report.speakerEmbeddingCount)]
          xVectorOnlyMode: \(prepared.report.xVectorOnlyMode)
          iclMode: true
        """)

        print("""
        [TuringQwenNativeBaseClone] model loaded
          modelID: \(prompt.cloneProfile.modelID)
          ttsModelType: \(config.ttsModelType)
          quantization: \(config.quantization?.bits ?? 0)bit
          weightBackend: mlxQuantizedMatmul
        """)

        print("""
        [TuringQwenNativeBaseClone] prompt built
          layout: \(prepared.prompt.layout)
          targetTokenCount: \(prepared.report.targetTokenCount)
          sequenceLength: \(promptInputs.sequenceLength)
          languageCodecID: \(prepared.report.languageCodecID)
        """)

        print("""
        [TuringQwenNativeBaseClone] dynamic generation started
          voiceID: \(prompt.cloneProfile.voiceID)
          variantID: \(prepared.report.variantID)
          fixtureRowsUsed: false
          xVectorOnlyMode: false
          mode: icl
          residentWeights: true
          runtimePerStepFileIO: false
        """)

        print("""
        [TuringQwenNativePerf] generation started
          modelID: \(prompt.cloneProfile.modelID)
          fixtureRowsUsed: false
          performanceMode: \(prompt.performanceMode.rawValue)
          weightBackend: mlxQuantizedMatmul
          residentWeights: true
          talkerKVCache: oneStep
          codePredictorKVCache: oneStep
        """)

        let initialTalkerStart = Date()
        let talkerOutput = try TuringQwenNativeTalkerForwardRunner.runFullForward(
            promptInputs: promptInputs,
            config: config,
            weightsStore: resident.weightsStore,
            maxNewRows: prompt.maxNewRows,
            resolvedWeights: resident.talkerWeights,
            performanceMode: prompt.performanceMode
        )
        let initialTalkerForwardSeconds = Date().timeIntervalSince(initialTalkerStart)
        let logits = TuringQwenNativeTalkerForwardRunner.codecHeadLogits(
            finalLastHiddenState: talkerOutput.finalLastHiddenState,
            codecHeadWeight: resident.talkerWeights.codecHeadWeight,
            performanceMode: prompt.performanceMode
        )
        eval(logits)
        let firstCodecToken = try TuringQwenNativeCodecSampler.selectFirstCodecToken(
            logits: logits,
            sequenceLength: talkerOutput.sequenceLength,
            vocabSize: config.talkerConfig.vocabSize
        )

        print("""
        [TuringQwenNativeBaseClone] first codec token selected
          tokenID: \(firstCodecToken.tokenID)
          sampling: greedy_argmax
        """)

        let dynamicCodebook = try generateDynamicCodebook(
            initialFirstCodecToken: firstCodecToken.tokenID,
            initialTalkerLastHiddenState: talkerOutput.finalLastHiddenState,
            initialKVCache: talkerOutput.kvCache,
            promptInputs: promptInputs,
            maxNewRows: prompt.maxNewRows,
            performanceMode: prompt.performanceMode,
            resident: resident
        )
        guard dynamicCodebook.rows.isEmpty == false else {
            throw TuringQwenNativeError.invalidConfig(
                "Base clone generated no codec rows before EOS."
            )
        }

        return GeneratedCodebookForDecode(
            generatedRows: dynamicCodebook.rows.map(\.tokenIDs),
            referenceRows: prepared.prompt.referenceCodes.map { row in
                row.map(Int.init)
            },
            initialPromptSeconds: initialPromptSeconds,
            initialTalkerForwardSeconds: initialTalkerForwardSeconds,
            talkerOneStepTotalSeconds: dynamicCodebook.talkerOneStepTotalSeconds,
            codePredictorTotalSeconds: dynamicCodebook.codePredictorTotalSeconds
        )
    }

    public func preflightBaseClone(
        prompt: TuringQwenNativeBaseClonePrompt
    ) async throws -> TuringQwenNativeBaseClonePreflightReport {
        trace.stageStarted(.promptBuild)
        defer {
            trace.stageCompleted(.promptBuild)
        }

        let prepared = try prepareBaseClonePrompt(prompt)

        print("""
        [TuringQwenNativeBaseClone] runtime preflight passed
          voiceID: \(prepared.report.voiceID)
          variantID: \(prepared.report.variantID)
          modelID: \(prepared.report.modelID)
          ttsModelType: \(prepared.report.ttsModelType)
          quantization: \(prepared.report.quantizationBits)bit
          targetTokenCount: \(prepared.report.targetTokenCount)
          refTextTokenCount: \(prepared.report.refTextTokenCount)
          referenceRows: \(prepared.report.referenceRowCount)
          codebookCount: \(prepared.report.codebookCount)
          speakerEmbeddingShape: [\(prepared.report.speakerEmbeddingCount)]
          languageCodecID: \(prepared.report.languageCodecID)
          xVectorOnlyMode: \(prepared.report.xVectorOnlyMode)
          iclMode: true
          runtimeRefAudioUsed: false
          runtimeRefTextUsed: false
          fixtureRowsUsed: false
          modelForwardStarted: false
        """)

        return prepared.report
    }

    public func releaseResidentState(
        reason: String,
        logMemorySnapshot: Bool = true
    ) {
        residentWeights = nil
        TuringQwenNativeMemoryControl.clearCache(
            label: "baseClone.releaseResidentState.\(reason)",
            shouldLogSnapshot: logMemorySnapshot
        )
        if logMemorySnapshot {
            print("""
            [TuringQwenNativeBaseClone] resident state released
              reason: \(reason)
              residentWeights: false
            """)
        }
    }

    private func prepareBaseClonePrompt(
        _ prompt: TuringQwenNativeBaseClonePrompt
    ) throws -> PreparedBaseClone {
        let conditioning = try TuringQwenNativeBaseCloneConditioningBuilder()
            .load(profile: prompt.cloneProfile)
        let tokenizer = try TuringQwenNativeTokenizer(modelRoot: modelRoot)
        let preparedPrompt = try TuringQwenNativeBaseCloneInputBuilder.build(
            request: TuringQwenNativeBaseClonePromptRequest(
                targetText: prompt.text,
                targetLanguage: prompt.language,
                cloneArtifacts: conditioning.artifacts,
                referenceRowLimit: prompt.referenceRowLimit,
                referenceWindowStrategy: prompt.referenceWindowStrategy
            ),
            config: config,
            tokenizer: tokenizer
        )

        let report = TuringQwenNativeBaseClonePreflightReport(
            voiceID: prompt.cloneProfile.voiceID,
            variantID: conditioning.variant.variantID,
            modelID: prompt.cloneProfile.modelID,
            ttsModelType: config.ttsModelType,
            quantizationBits: config.quantization?.bits ?? 0,
            targetTokenCount: preparedPrompt.targetInputIDs.count,
            refTextTokenCount: preparedPrompt.refTextTokens.count,
            referenceRowCount: preparedPrompt.referenceRowCount,
            originalReferenceRowCount: preparedPrompt.originalReferenceRowCount,
            referenceWindowStrategy: preparedPrompt.referenceWindowStrategy.rawValue,
            codebookCount: conditioning.artifacts.codebookCount,
            speakerEmbeddingCount: preparedPrompt.speakerEmbedding.count,
            languageCodecID: preparedPrompt.languageCodecID,
            xVectorOnlyMode: preparedPrompt.xVectorOnlyMode
        )

        return PreparedBaseClone(
            conditioning: conditioning,
            prompt: preparedPrompt,
            report: report
        )
    }

    private struct PreparedBaseClone: Sendable {
        let conditioning: TuringQwenNativeBaseCloneConditioning
        let prompt: TuringQwenNativePreparedBaseClonePrompt
        let report: TuringQwenNativeBaseClonePreflightReport
    }

    private struct DynamicCodebookResult: Sendable {
        let rows: [TuringQwenNativeFirstCodeGroup]
        let talkerOneStepTotalSeconds: Double
        let codePredictorTotalSeconds: Double
    }

    private struct GeneratedCodebookForDecode: Sendable {
        let generatedRows: [[Int]]
        let referenceRows: [[Int]]
        let initialPromptSeconds: Double
        let initialTalkerForwardSeconds: Double
        let talkerOneStepTotalSeconds: Double
        let codePredictorTotalSeconds: Double
    }

    private struct StaticPromptContextKey: Hashable {
        let voiceID: String
        let variantID: String
        let language: String
        let referenceRowLimit: Int?
        let referenceWindowStrategy: TuringQwenNativeReferenceWindowStrategy
    }

    private func loadResidentWeights() throws -> TuringQwenNativeResidentResources {
        if let sharedResidentResources {
            return sharedResidentResources
        }

        if let residentWeights {
            return residentWeights
        }

        let loaded = try TuringQwenNativeResidentResources(modelRoot: modelRoot)
        residentWeights = loaded

        print("""
        [TuringQwenNativeBaseClone] resident 4-bit weights loaded
          tensorCount: resident
          talkerLayerCount: \(config.talkerConfig.numHiddenLayers)
          codePredictorLayerCount: \(loaded.codePredictorWeights.config.numHiddenLayers)
          runtimePerStepWeightLookup: false
        """)

        return loaded
    }

    private func cachedStaticPromptContext(
        prompt: TuringQwenNativeBaseClonePrompt,
        prepared: TuringQwenNativePreparedBaseClonePrompt,
        resident: TuringQwenNativeResidentResources
    ) throws -> TuringQwenNativeBaseCloneStaticPromptContext {
        let key = StaticPromptContextKey(
            voiceID: prompt.cloneProfile.voiceID,
            variantID: prompt.cloneProfile.defaultVariantID,
            language: prompt.language.lowercased(),
            referenceRowLimit: prompt.referenceRowLimit,
            referenceWindowStrategy: prompt.referenceWindowStrategy
        )

        if let cached = staticPromptContexts[key] {
            print("""
            [TuringQwenNativeBaseClone] static clone prompt cache hit
              voiceID: \(key.voiceID)
              variantID: \(key.variantID)
              referenceRows: \(cached.referenceRowCount)
              refTextBodyTokens: \(cached.refTextTokenCount)
            """)
            return cached
        }

        let buildStart = Date()
        let built = try TuringQwenNativeBaseClonePromptInputBuilder.makeStaticContext(
            prepared: prepared,
            config: config,
            weightsStore: resident.weightsStore,
            codePredictorWeights: resident.codePredictorWeights
        )
        staticPromptContexts[key] = built

        print("""
        [TuringQwenNativeBaseClone] static clone prompt cache built
          voiceID: \(key.voiceID)
          variantID: \(key.variantID)
          referenceRows: \(built.referenceRowCount)
          refTextBodyTokens: \(built.refTextTokenCount)
          seconds: \(String(format: "%.3f", Date().timeIntervalSince(buildStart)))
        """)

        return built
    }

    private func generateDynamicCodebook(
        initialFirstCodecToken: Int,
        initialTalkerLastHiddenState: MLXArray,
        initialKVCache: TuringQwenNativeKVCache,
        promptInputs: TuringQwenNativeTalkerPromptInputs,
        maxNewRows: Int,
        performanceMode: TuringQwenNativePerformanceMode,
        resident: TuringQwenNativeResidentResources
    ) throws -> DynamicCodebookResult {
        let targetRowCount = max(maxNewRows, 1)
        let generationStart = Date()
        var generatedRows: [TuringQwenNativeFirstCodeGroup] = []
        var talkerOneStepTotalSeconds: Double = 0
        var codePredictorTotalSeconds: Double = 0
        var generationState = initialGenerationState(
            promptInputs: promptInputs,
            kvCache: initialKVCache
        )
        let segmentCache = TuringQwenNativeSegmentRuntimeCache(
            config: config,
            promptSequenceLength: promptInputs.sequenceLength,
            maxNewRows: targetRowCount,
            trailingTextHidden: promptInputs.trailingTextHidden,
            ttsPadEmbed: promptInputs.ttsPadEmbed
        )

        print("""
        [TuringQwenNativeBaseClone] dynamic codebook generation started
          maxNewRows: \(targetRowCount)
          performanceMode: \(performanceMode.rawValue)
          fixtureRowsUsed: false
          codePredictorKVCache: oneStep
          segmentRuntimeCache: enabled
          attentionKernel: \(performanceMode.shouldUseFastGroupedQueryAttention ? "mlxFastGroupedQuery" : "manualMatmulSoftmax")
          rmsNormKernel: \(performanceMode == .performance ? "mlxFast" : "manual")
          talkerInputEmbeddingAssembly: directSumNoConcat
        """)

        let firstCodeGroupStart = Date()
        let firstCodeGroup = try TuringQwenNativeCodePredictor.generateCodeGroup(
            firstCodecToken: initialFirstCodecToken,
            talkerLastHiddenState: initialTalkerLastHiddenState,
            config: config,
            weightsStore: resident.weightsStore,
            expectedFixtureRowIndex: nil,
            resolvedWeights: resident.codePredictorWeights,
            segmentCache: segmentCache,
            performanceMode: performanceMode
        )
        codePredictorTotalSeconds += Date().timeIntervalSince(firstCodeGroupStart)
        logGeneratedRow(
            rowIndex: 0,
            firstCodecToken: initialFirstCodecToken,
            tokenIDs: performanceMode.shouldLogFullTokenRows ? firstCodeGroup.tokenIDs : [],
            generationStart: generationStart,
            performanceMode: performanceMode
        )

        if let stopReason = shouldStopAfterFirstCodecToken(
            initialFirstCodecToken,
            step: 0,
            maxNewRows: targetRowCount
        ) {
            print("""
            [TuringQwenNativeBaseClone] dynamic stop selected
              rowIndex: 0
              stopReason: \(stopReason.rawValue)
              excludedFromDecode: \(stopReason == .eos)
            """)
            if stopReason == .eos {
                return DynamicCodebookResult(
                    rows: generatedRows,
                    talkerOneStepTotalSeconds: talkerOneStepTotalSeconds,
                    codePredictorTotalSeconds: codePredictorTotalSeconds
                )
            }
        }

        generatedRows.append(firstCodeGroup)

        while generatedRows.count < targetRowCount {
            let rowIndex = generatedRows.count
            let nextInput = try nextTalkerInputEmbedding(
                codeGroup: generatedRows[rowIndex - 1],
                generationStep: rowIndex - 1,
                promptInputs: promptInputs,
                resident: resident,
                segmentCache: segmentCache,
                performanceMode: performanceMode
            )
            let nextStep = try TuringQwenNativeTalkerForwardRunner.forwardOneStep(
                inputEmbedding: nextInput,
                previousState: generationState,
                config: config,
                weightsStore: resident.weightsStore,
                resolvedWeights: resident.talkerWeights,
                codePredictorWeights: resident.codePredictorWeights,
                segmentCache: segmentCache,
                performanceMode: performanceMode
            )
            talkerOneStepTotalSeconds += nextStep.talkerStepSeconds
            codePredictorTotalSeconds += nextStep.codePredictorSeconds
            generationState = nextStep.state
            logGeneratedRow(
                rowIndex: rowIndex,
                firstCodecToken: nextStep.firstCodecToken,
                tokenIDs: performanceMode.shouldLogFullTokenRows ? nextStep.codeGroup.tokenIDs : [],
                generationStart: generationStart,
                performanceMode: performanceMode
            )

            if let stopReason = shouldStopAfterFirstCodecToken(
                nextStep.firstCodecToken,
                step: rowIndex,
                maxNewRows: targetRowCount
            ) {
                print("""
                [TuringQwenNativeBaseClone] dynamic stop selected
                  rowIndex: \(rowIndex)
                  stopReason: \(stopReason.rawValue)
                  excludedFromDecode: \(stopReason == .eos)
                """)
                if stopReason == .eos {
                    break
                }
            }

            generatedRows.append(nextStep.codeGroup)
        }

        print("""
        [TuringQwenNativeBaseClone] dynamic codebook generation finished
          rowCount: \(generatedRows.count)
          elapsedSeconds: \(String(format: "%.3f", Date().timeIntervalSince(generationStart)))
          fixtureRowsUsed: false
        """)

        return DynamicCodebookResult(
            rows: generatedRows,
            talkerOneStepTotalSeconds: talkerOneStepTotalSeconds,
            codePredictorTotalSeconds: codePredictorTotalSeconds
        )
    }

    private func initialGenerationState(
        promptInputs: TuringQwenNativeTalkerPromptInputs,
        kvCache: TuringQwenNativeKVCache
    ) -> TuringQwenNativeTalkerGenerationState {
        return TuringQwenNativeTalkerGenerationState(
            kvCache: kvCache,
            position: promptInputs.sequenceLength
        )
    }

    private func shouldStopAfterFirstCodecToken(
        _ firstCodecToken: Int,
        step: Int,
        maxNewRows: Int
    ) -> TuringQwenNativeStopReason? {
        if firstCodecToken == config.talkerConfig.codecEosTokenID {
            return .eos
        }

        if step + 1 >= maxNewRows {
            return .maxTokens
        }

        return nil
    }

    private func nextTalkerInputEmbedding(
        codeGroup: TuringQwenNativeFirstCodeGroup,
        generationStep: Int,
        promptInputs: TuringQwenNativeTalkerPromptInputs,
        resident: TuringQwenNativeResidentResources,
        segmentCache: TuringQwenNativeSegmentRuntimeCache,
        performanceMode: TuringQwenNativePerformanceMode
    ) throws -> MLXArray {
        let codeEmbedding = try TuringQwenNativeCodePredictor.talkerInputEmbedding(
            forCodeGroupTokenArray: codeGroup.tokenArray,
            config: config,
            resolvedWeights: resident.codePredictorWeights
        )

        let trailingHidden = segmentCache.talkerTrailingTextEmbed(generationStep: generationStep) ??
            promptInputs.ttsPadEmbed

        let input = codeEmbedding + trailingHidden
        if performanceMode.shouldForceEveryEval {
            eval(input)
        }
        return input
    }

    private func logGeneratedRow(
        rowIndex: Int,
        firstCodecToken: Int,
        tokenIDs: [Int],
        generationStart: Date,
        performanceMode: TuringQwenNativePerformanceMode
    ) {
        if performanceMode.shouldLogFullTokenRows {
            print("""
            [TuringQwenNativeBaseClone] dynamic codebook row generated
              rowIndex: \(rowIndex)
              firstCodecToken: \(firstCodecToken)
              tokenIDs: \(tokenIDs)
              fixtureRowsUsed: false
            """)
            return
        }

        guard rowIndex == 0 ||
              (rowIndex + 1) % performanceMode.rowCheckpointStride == 0 else {
            return
        }

        let elapsed = Date().timeIntervalSince(generationStart)
        let completedRows = rowIndex + 1
        let audioSeconds = Double(completedRows) * 1920.0 / 24_000.0
        let realTimeFactor = TuringQwenNativeRealtimeBudgetProbe.realTimeFactor(
            renderSeconds: elapsed,
            audioDurationSeconds: audioSeconds
        )

        print("""
        [TuringQwenNativeBaseClonePerf] dynamic codebook checkpoint
          rowIndex: \(rowIndex)
          completedRows: \(completedRows)
          averageSecondsPerRow: \(String(format: "%.3f", elapsed / Double(completedRows)))
          projectedRealTimeFactor: \(String(format: "%.3f", realTimeFactor))
          fixtureRowsUsed: false
        """)
    }

    private static func preflightModelRoot(_ root: URL) throws {
        let required = [
            "config.json",
            "model.safetensors",
            "tokenizer_config.json",
            "vocab.json",
            "merges.txt",
            "speech_tokenizer"
        ]

        for relativePath in required {
            let url = root.appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw TuringQwenNativeError.missingModelFile(relativePath)
            }
        }

        let configURL = root.appendingPathComponent("config.json")
        let config = try TuringQwenNativeConfig.load(from: root)
        try config.validateBaseCloneRuntime()
        let data = try Data(contentsOf: configURL)
        let baseConfig = try JSONDecoder().decode(BaseConfig.self, from: data)
        guard baseConfig.modelType == "qwen3_tts" else {
            throw TuringQwenNativeError.invalidConfig(
                "model_type must be qwen3_tts, got \(baseConfig.modelType)"
            )
        }
        guard baseConfig.ttsModelType == "base" else {
            throw TuringQwenNativeError.invalidConfig(
                "tts_model_type must be base for Base clone runtime, got \(baseConfig.ttsModelType)"
            )
        }
    }

    private struct BaseConfig: Decodable {
        let modelType: String
        let ttsModelType: String

        enum CodingKeys: String, CodingKey {
            case modelType = "model_type"
            case ttsModelType = "tts_model_type"
        }
    }
}
