import Foundation
import MLX

public struct TuringQwenNativeAudio: Sendable {
    public let samples: [Float]
    public let sampleRate: Int

    public var peakAbs: Float {
        samples.reduce(Float(0)) { max($0, abs($1)) }
    }

    public var rms: Float {
        guard samples.isEmpty == false else { return 0 }
        let sum = samples.reduce(Double(0)) {
            $0 + Double($1 * $1)
        }
        return Float(sqrt(sum / Double(samples.count)))
    }

    public var durationSeconds: Double {
        guard sampleRate > 0 else { return 0 }
        return Double(samples.count) / Double(sampleRate)
    }
}

public actor TuringQwenNativeVoiceDesignEngine {
    private let modelRoot: URL
    private let trace: TuringQwenNativeTrace
    private let breadcrumbs: TuringQwenNativeStageBreadcrumbs
    private let rowBudgetRecorder: TuringQwenNativeRowBudgetRecorder
    private let config: TuringQwenNativeConfig
    private let tensorIndex: TuringQwenNativeSafetensorsIndex
    private let weightsStore: TuringQwenNativeWeightsStore
    private let talkerWeights: TuringQwenNativeTalkerResolvedWeights
    private let codePredictorWeights: TuringQwenNativeCodePredictorResolvedWeights

    public init(
        modelRoot: URL,
        trace: TuringQwenNativeTrace
    ) async throws {
        TuringQwenNativeMemoryControl.configureForCanary()

        self.modelRoot = modelRoot
        self.trace = trace
        self.breadcrumbs = try TuringQwenNativeStageBreadcrumbs()
        self.rowBudgetRecorder = try TuringQwenNativeRowBudgetRecorder()

        breadcrumbs.logPreviousRunIfNeeded(prefix: "[TuringQwenNativeHello]")
        rowBudgetRecorder.logPreviousRunIfNeeded(prefix: "[TuringQwenNativeHello]")

        self.config = try Self.withStage(
            .assetPreflight,
            trace: trace,
            breadcrumbs: breadcrumbs
        ) {
            try Self.preflightAssets(modelRoot: modelRoot)
            return try TuringQwenNativeConfig.load(from: modelRoot)
        }

        let loadedTensorIndex = try Self.withStage(
            .tensorIndexLoad,
            trace: trace,
            breadcrumbs: breadcrumbs
        ) {
            try TuringQwenNativeSafetensorsIndex.load(
                from: modelRoot.appendingPathComponent("model.safetensors")
            )
        }
        self.tensorIndex = loadedTensorIndex

        try Self.withStage(
            .weightMapValidate,
            trace: trace,
            breadcrumbs: breadcrumbs
        ) {
            try Self.validateWeightMap(loadedTensorIndex)
        }

        let loadedWeightsStore = try Self.withStage(
            .weightMapValidate,
            trace: trace,
            breadcrumbs: breadcrumbs
        ) {
            try TuringQwenNativeWeightsStore(modelRoot: modelRoot)
        }
        self.weightsStore = loadedWeightsStore
        self.talkerWeights = try TuringQwenNativeTalkerResolvedWeights(
            config: config,
            weightsStore: loadedWeightsStore
        )
        self.codePredictorWeights = try TuringQwenNativeCodePredictorResolvedWeights(
            config: config,
            weightsStore: loadedWeightsStore
        )
        print("""
        [TuringQwenNative] hot path weights resolved
          talkerLayerCount: \(config.talkerConfig.numHiddenLayers)
          codePredictorLayerCount: \(codePredictorWeights.config.numHiddenLayers)
          runtimePerStepWeightLookup: false
        """)
    }

    public static var sourceTruthFixtureRows: [[Int]] {
        TuringQwenNativeCodePredictor.expectedFixtureRows
    }

    public func generateVoiceDesignFixtureDecode(
        text: String,
        instruct: String,
        fixtureRows: [[Int]],
        memoryLabel: String
    ) async throws -> TuringQwenNativeAudio {
        print("""
        [TuringQwenNative] fixture decode started
          mode: fixtureDecode
          textUTF16: \(text.utf16.count)
          instructUTF16: \(instruct.utf16.count)
          rowCount: \(fixtureRows.count)
          fixtureRowsUsed: true
          memoryLabel: \(memoryLabel)
        """)
        TuringQwenNativeMemoryProbe.log(stage: "beforeDecode", rowCount: fixtureRows.count)

        let audio = try TuringQwenNativeSpeechDecoder.decode(
            codebookRows: fixtureRows,
            modelRoot: modelRoot
        )

        TuringQwenNativeMemoryProbe.log(stage: "afterDecode", rowCount: fixtureRows.count)
        print("""
        [TuringQwenNative] decode finished
              mode: fixtureDecode
              fixtureRowsUsed: true
              sampleRate: \(audio.sampleRate)
              sampleCount: \(audio.samples.count)
              durationSeconds: \(String(format: "%.3f", audio.durationSeconds))
              peakAbs: \(audio.peakAbs)
              rms: \(audio.rms)
        """)
        return audio
    }

    public func generateVoiceDesignDynamic(
        text: String,
        instruct: String,
        maxNewTokens: Int,
        memoryLabel: String,
        performanceMode: TuringQwenNativePerformanceMode = .diagnostic
    ) async throws -> TuringQwenNativeAudio {
        try await generateVoiceDesign(
            text: text,
            voiceDescription: instruct,
            language: "english",
            maxNewTokens: maxNewTokens,
            seed: 0,
            memoryLabel: memoryLabel,
            performanceMode: performanceMode
        )
    }

    public func generateVoiceDesign(
        text: String,
        voiceDescription: String,
        language: String,
        maxNewTokens: Int,
        seed: UInt64
    ) async throws -> TuringQwenNativeAudio {
        try await generateVoiceDesign(
            text: text,
            voiceDescription: voiceDescription,
            language: language,
            maxNewTokens: maxNewTokens,
            seed: seed,
            memoryLabel: "legacy",
            performanceMode: .diagnostic
        )
    }

    private func generateVoiceDesign(
        text: String,
        voiceDescription: String,
        language: String,
        maxNewTokens: Int,
        seed: UInt64,
        memoryLabel: String,
        performanceMode: TuringQwenNativePerformanceMode
    ) async throws -> TuringQwenNativeAudio {
        let renderStart = Date()
        let generationModeLabel = performanceMode == .performance
            ? "dynamicPerformance"
            : "dynamicDebug"
        rowBudgetRecorder.started(
            targetRows: maxNewTokens,
            memoryLabel: memoryLabel
        )
        print("""
        [TuringQwenNative] dynamic generation started
          mode: \(generationModeLabel)
          performanceMode: \(performanceMode.rawValue)
          textUTF16: \(text.utf16.count)
          instructUTF16: \(voiceDescription.utf16.count)
          maxNewRows: \(maxNewTokens)
          seed: \(seed)
          fixtureRowsUsed: false
          memoryLabel: \(memoryLabel)
          residentWeights: true
          kvCacheMode: appendPreallocated
          codePredictorKVCache: oneStep
          runtimePerStepFileIO: false
        """)
        TuringQwenNativeMemoryProbe.log(stage: "beforePrompt")

        let tokenizer = try Self.withStage(
            .tokenizerLoad,
            trace: trace,
            breadcrumbs: breadcrumbs
        ) {
            try Self.preflightTokenizer(modelRoot: modelRoot)
            return try TuringQwenNativeTokenizer(modelRoot: modelRoot)
        }

        let prompt = try Self.withStage(
            .promptBuild,
            trace: trace,
            breadcrumbs: breadcrumbs
        ) {
            try TuringQwenNativeVoiceDesignPromptBuilder.build(
                text: text,
                voiceDescription: voiceDescription,
                language: language,
                englishLanguageID: config.talkerConfig.codecLanguageID["english"],
                tokenizer: tokenizer
            )
        }

        trace.tensor(
            "prompt.assistantInputIDs",
            shape: [1, prompt.assistantInputIDs.count],
            dtype: "int64",
            ndim: 2
        )
        trace.tensor(
            "prompt.instructInputIDs",
            shape: [1, prompt.instructInputIDs.count],
            dtype: "int64",
            ndim: 2
        )

        try Self.withStage(
            .promptEmbeddingsEval,
            trace: trace,
            breadcrumbs: breadcrumbs
        ) {
            let assistantIDs = MLXArray(
                int64: prompt.assistantInputIDs,
                [1, prompt.assistantInputIDs.count]
            )
            let instructIDs = MLXArray(
                int64: prompt.instructInputIDs,
                [1, prompt.instructInputIDs.count]
            )
            eval(assistantIDs, instructIDs)
        }

        let talkerPromptInputs = try Self.withStage(
            .talkerPromptInputEval,
            trace: trace,
            breadcrumbs: breadcrumbs
        ) {
            try TuringQwenNativeTalkerPromptInputBuilder.build(
                prompt: prompt,
                config: config,
                tensorIndex: tensorIndex
            )
        }

        trace.tensor(
            "talker.inputsEmbeds",
            shape: [1, talkerPromptInputs.sequenceLength, talkerPromptInputs.hiddenSize],
            dtype: "float32",
            ndim: 3
        )
        trace.tensor(
            "talker.attentionMask",
            shape: [1, talkerPromptInputs.sequenceLength],
            dtype: "int64",
            ndim: 2
        )
        trace.tensor(
            "talker.trailingTextHidden",
            shape: [1, 1, talkerPromptInputs.hiddenSize],
            dtype: "float32",
            ndim: 3
        )
        trace.tensor(
            "talker.ttsPadEmbed",
            shape: [1, 1, talkerPromptInputs.hiddenSize],
            dtype: "float32",
            ndim: 3
        )

        breadcrumbs.started(.talkerAllLayersEval)
        trace.stageStarted(.talkerAllLayersEval)
        let talkerOutput: TuringQwenNativeTalkerForwardOutput
        do {
            talkerOutput = try TuringQwenNativeTalkerForwardRunner.runFullForward(
                promptInputs: talkerPromptInputs,
                config: config,
                weightsStore: weightsStore,
                maxNewRows: maxNewTokens,
                resolvedWeights: talkerWeights
            )
            breadcrumbs.completed(.talkerAllLayersEval)
            trace.stageCompleted(.talkerAllLayersEval)
        } catch {
            throw error
        }

        trace.tensor(
            "talker.finalLastHiddenState",
            shape: [1, 1, talkerOutput.hiddenSize],
            dtype: "float32",
            ndim: 3
        )
        print("""
        [TuringQwenNative] initial talker forward finished
          promptLength: \(talkerOutput.sequenceLength)
          hiddenShape: [1, 1, \(talkerOutput.hiddenSize)]
          kvCacheLayers: \(config.talkerConfig.numHiddenLayers)
          graphRetainedInCache: false
        """)
        if performanceMode.shouldLogFullTokenRows {
            TuringQwenNativeMemoryProbe.log(stage: "afterInitialForward")
        }
        if performanceMode.shouldClearMLXCacheEveryRow {
            TuringQwenNativeMemoryControl.clearCache(label: "afterTalkerForward")
        }

        breadcrumbs.started(.talkerCodecHeadEval)
        trace.stageStarted(.talkerCodecHeadEval)
        let logits: MLXArray
        do {
            logits = TuringQwenNativeTalkerForwardRunner.codecHeadLogits(
                finalLastHiddenState: talkerOutput.finalLastHiddenState,
                codecHeadWeight: talkerWeights.codecHeadWeight
            )
            breadcrumbs.completed(.talkerCodecHeadEval)
            trace.stageCompleted(.talkerCodecHeadEval)
        } catch {
            throw error
        }

        eval(logits)
        trace.tensor(
            "talker.logits",
            shape: [1, 1, config.talkerConfig.vocabSize],
            dtype: "float32",
            ndim: 3
        )

        breadcrumbs.started(.sampleFirstToken)
        trace.stageStarted(.sampleFirstToken)
        let firstCodecToken: TuringQwenNativeFirstCodecToken
        do {
            firstCodecToken = try TuringQwenNativeCodecSampler.selectFirstCodecToken(
                logits: logits,
                sequenceLength: talkerOutput.sequenceLength,
                vocabSize: config.talkerConfig.vocabSize
            )
            breadcrumbs.completed(.sampleFirstToken)
            trace.stageCompleted(.sampleFirstToken)
        } catch {
            throw error
        }

        print("""
        [TuringQwenNative] first codec token selected
          tokenID: \(firstCodecToken.tokenID)
          expectedFixtureTokenID: \(firstCodecToken.expectedFixtureTokenID)
          matchesFixture: \(firstCodecToken.matchesFixture)
          sampling: greedy_argmax
        """)

        breadcrumbs.started(.codePredictorCodebookEval)
        trace.stageStarted(.codePredictorCodebookEval)
        let generatedCodebook: [[Int]]
        let codePredictorStart = Date()
        do {
            generatedCodebook = try generateDynamicCodebook(
                initialFirstCodecToken: firstCodecToken.tokenID,
                initialTalkerLastHiddenState: talkerOutput.finalLastHiddenState,
                initialKVCache: talkerOutput.kvCache,
                promptInputs: talkerPromptInputs,
                maxNewRows: maxNewTokens,
                performanceMode: performanceMode
            )
            breadcrumbs.completed(.codePredictorCodebookEval)
            trace.stageCompleted(.codePredictorCodebookEval)
        } catch {
            throw error
        }
        let codePredictorSeconds = Date().timeIntervalSince(codePredictorStart)

        print("""
        [TuringQwenNative] dynamic generation finished
          rowCount: \(generatedCodebook.count)
          shape: [\(generatedCodebook.count), \(generatedCodebook.first?.count ?? 0)]
          stopReason: \(generatedCodebook.count >= maxNewTokens ? "maxRows" : "eos")
          fixtureRowsUsed: false
          sampling: greedy_argmax
        """)

        breadcrumbs.started(.speechDecoderFirstEval)
        trace.stageStarted(.speechDecoderFirstEval)
        do {
            if performanceMode.shouldLogFullTokenRows {
                TuringQwenNativeMemoryProbe.log(stage: "beforeDecode", rowCount: generatedCodebook.count)
            }
            let decodeStart = Date()
            let audio = try TuringQwenNativeSpeechDecoder.decode(
                codebookRows: generatedCodebook,
                modelRoot: modelRoot
            )
            let decodeSeconds = Date().timeIntervalSince(decodeStart)
            breadcrumbs.completed(.speechDecoderFirstEval)
            trace.stageCompleted(.speechDecoderFirstEval)
            if performanceMode.shouldLogFullTokenRows {
                TuringQwenNativeMemoryProbe.log(stage: "afterDecode", rowCount: generatedCodebook.count)
            }
            rowBudgetRecorder.finished(completedRows: generatedCodebook.count)
            let renderSeconds = Date().timeIntervalSince(renderStart)
            let realTimeFactor = TuringQwenNativeRealtimeBudgetProbe.realTimeFactor(
                renderSeconds: renderSeconds,
                audioDurationSeconds: audio.durationSeconds
            )

            print("""
            [TuringQwenNative] decode finished
              mode: \(generationModeLabel)
              fixtureRowsUsed: false
              sampleCount: \(audio.samples.count)
              sampleRate: \(audio.sampleRate)
              durationSeconds: \(String(format: "%.3f", audio.durationSeconds))
              peakAbs: \(audio.peakAbs)
              rms: \(audio.rms)
            """)

            print("""
            [TuringQwenNativePerf] generation finished
              mode: \(generationModeLabel)
              rowCount: \(generatedCodebook.count)
              audioDurationSeconds: \(String(format: "%.3f", audio.durationSeconds))
              renderSeconds: \(String(format: "%.3f", renderSeconds))
              realTimeFactor: \(String(format: "%.3f", realTimeFactor))
              codePredictorSeconds: \(String(format: "%.3f", codePredictorSeconds))
              decodeSeconds: \(String(format: "%.3f", decodeSeconds))
              codePredictorKVCache: oneStep
              fixtureRowsUsed: false
            """)

            return audio
        } catch {
            throw error
        }
    }

    private func generateDynamicCodebook(
        initialFirstCodecToken: Int,
        initialTalkerLastHiddenState: MLXArray,
        initialKVCache: TuringQwenNativeKVCache,
        promptInputs: TuringQwenNativeTalkerPromptInputs,
        maxNewRows: Int,
        performanceMode: TuringQwenNativePerformanceMode
    ) throws -> [[Int]] {
        let targetRowCount = max(maxNewRows, 1)
        let generationStart = Date()
        var generatedRows: [[Int]] = []
        var talkerOneStepSeconds = Double(0)
        var codePredictorGroupSeconds = Double(0)
        var generationState = initialGenerationState(
            promptInputs: promptInputs,
            kvCache: initialKVCache
        )

        print("""
        [TuringQwenNative] dynamic codebook generation started
          maxNewRows: \(targetRowCount)
          performanceMode: \(performanceMode.rawValue)
          fixtureRowsUsed: false
          residentWeights: true
          kvCacheMode: appendPreallocated
          codePredictorKVCache: oneStep
          runtimePerStepFileIO: false
        """)

        if performanceMode.shouldWriteRowBudgetEveryRow {
            rowBudgetRecorder.startedRow(0)
        }
        let firstCodeGroupStart = Date()
        let firstCodeGroup = try TuringQwenNativeCodePredictor.generateCodeGroup(
            firstCodecToken: initialFirstCodecToken,
            talkerLastHiddenState: initialTalkerLastHiddenState,
            config: config,
            weightsStore: weightsStore,
            expectedFixtureRowIndex: nil,
            resolvedWeights: codePredictorWeights,
            performanceMode: performanceMode
        )
        codePredictorGroupSeconds += Date().timeIntervalSince(firstCodeGroupStart)

        logGeneratedRow(
            rowIndex: 0,
            firstCodecToken: initialFirstCodecToken,
            tokenIDs: firstCodeGroup.tokenIDs,
            generationStart: generationStart,
            performanceMode: performanceMode
        )

        if let stopReason = shouldStopAfterCodeGroup(
            firstCodeGroup.tokenIDs,
            step: 0,
            maxNewTokens: targetRowCount
        ) {
            print("""
            [TuringQwenNative] dynamic stop selected
              rowIndex: 0
              stopReason: \(stopReason.rawValue)
              excludedFromDecode: \(stopReason == .eos)
              fixtureRowsUsed: false
            """)
            if stopReason == .eos {
                return generatedRows
            }
        }

        generatedRows.append(firstCodeGroup.tokenIDs)
        if performanceMode.shouldWriteRowBudgetEveryRow {
            rowBudgetRecorder.completedRows(generatedRows.count)
        }

        if generatedRows.count >= targetRowCount {
            return generatedRows
        }

        while generatedRows.count < targetRowCount {
            let rowIndex = generatedRows.count
            if performanceMode.shouldWriteRowBudgetEveryRow {
                rowBudgetRecorder.startedRow(rowIndex)
            }
            let nextInput = try nextTalkerInputEmbedding(
                codeGroup: generatedRows[rowIndex - 1],
                generationStep: rowIndex - 1,
                promptInputs: promptInputs,
                performanceMode: performanceMode
            )
            let nextStep = try TuringQwenNativeTalkerForwardRunner.forwardOneStep(
                inputEmbedding: nextInput,
                previousState: generationState,
                config: config,
                weightsStore: weightsStore,
                resolvedWeights: talkerWeights,
                codePredictorWeights: codePredictorWeights,
                performanceMode: performanceMode
            )
            generationState = nextStep.state
            talkerOneStepSeconds += nextStep.talkerStepSeconds
            codePredictorGroupSeconds += nextStep.codePredictorSeconds

            logGeneratedRow(
                rowIndex: rowIndex,
                firstCodecToken: nextStep.firstCodecToken,
                tokenIDs: nextStep.codeGroup,
                generationStart: generationStart,
                performanceMode: performanceMode
            )

            if let stopReason = shouldStopAfterCodeGroup(
                nextStep.codeGroup,
                step: rowIndex,
                maxNewTokens: targetRowCount
            ) {
                print("""
                [TuringQwenNative] dynamic stop selected
                  rowIndex: \(rowIndex)
                  stopReason: \(stopReason.rawValue)
                  excludedFromDecode: \(stopReason == .eos)
                  fixtureRowsUsed: false
                """)
                if stopReason == .eos {
                    break
                }
            }

            generatedRows.append(nextStep.codeGroup)
            if performanceMode.shouldWriteRowBudgetEveryRow {
                rowBudgetRecorder.completedRows(generatedRows.count)
            }

            if generatedRows.count >= targetRowCount {
                break
            }

            if performanceMode.shouldClearMLXCacheEveryRow {
                TuringQwenNativeMemoryControl.clearCache(label: "dynamicCodebook.row.\(rowIndex)")
            }
        }

        let elapsed = Date().timeIntervalSince(generationStart)
        print("""
        [TuringQwenNativePerf] dynamic codebook timing
          rowCount: \(generatedRows.count)
          totalSeconds: \(String(format: "%.3f", elapsed))
          talkerOneStepSeconds: \(String(format: "%.3f", talkerOneStepSeconds))
          codePredictorGroupSeconds: \(String(format: "%.3f", codePredictorGroupSeconds))
          otherLoopSeconds: \(String(format: "%.3f", max(0, elapsed - talkerOneStepSeconds - codePredictorGroupSeconds)))
          runtimePerStepWeightLookup: false
        """)

        return generatedRows
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
            [TuringQwenNative] dynamic codebook row generated
              rowIndex: \(rowIndex)
              firstCodecToken: \(firstCodecToken)
              tokenIDs: \(tokenIDs)
              fixtureRowsUsed: false
            """)
            TuringQwenNativeMemoryProbe.log(stage: "afterRow", rowIndex: rowIndex)
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
        [TuringQwenNativePerf] dynamic codebook checkpoint
          rowIndex: \(rowIndex)
          completedRows: \(completedRows)
          averageSecondsPerRow: \(String(format: "%.3f", elapsed / Double(completedRows)))
          projectedRealTimeFactor: \(String(format: "%.3f", realTimeFactor))
          codePredictorKVCache: oneStep
          fixtureRowsUsed: false
        """)
    }

    private func initialGenerationState(
        promptInputs: TuringQwenNativeTalkerPromptInputs,
        kvCache: TuringQwenNativeKVCache
    ) -> TuringQwenNativeTalkerGenerationState {
        let mask = MLXArray(
            int64: Array(repeating: 1, count: promptInputs.sequenceLength),
            [1, promptInputs.sequenceLength]
        )

        return TuringQwenNativeTalkerGenerationState(
            kvCache: kvCache,
            position: promptInputs.sequenceLength,
            attentionMask: mask
        )
    }

    private func shouldStopAfterCodeGroup(
        _ codeGroup: [Int],
        step: Int,
        maxNewTokens: Int
    ) -> TuringQwenNativeStopReason? {
        if codeGroup.first == config.talkerConfig.codecEosTokenID {
            return .eos
        }

        if step + 1 >= maxNewTokens {
            return .maxTokens
        }

        return nil
    }

    private func nextTalkerInputEmbedding(
        codeGroup: [Int],
        generationStep: Int,
        promptInputs: TuringQwenNativeTalkerPromptInputs,
        performanceMode: TuringQwenNativePerformanceMode
    ) throws -> MLXArray {
        let codeEmbedding = try TuringQwenNativeCodePredictor.talkerInputEmbedding(
            forCodeGroup: codeGroup,
            config: config,
            resolvedWeights: codePredictorWeights
        )

        let trailingHidden: MLXArray
        if generationStep < promptInputs.trailingTextHidden.dim(1) {
            trailingHidden = promptInputs.trailingTextHidden[
                generationStep..<(generationStep + 1),
                axis: 1
            ]
        } else {
            trailingHidden = promptInputs.ttsPadEmbed
        }

        let input = codeEmbedding + trailingHidden
        if performanceMode.shouldForceEveryEval {
            eval(input)
        }
        return input
    }

    private static func preflightAssets(modelRoot: URL) throws {
        let required = [
            "config.json",
            "generation_config.json",
            "model.safetensors",
            "model.safetensors.index.json",
            "tokenizer_config.json",
            "vocab.json",
            "merges.txt",
            "speech_tokenizer/config.json",
            "speech_tokenizer/model.safetensors"
        ]

        for name in required {
            let url = modelRoot.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw TuringQwenNativeError.missingModelFile(name)
            }
        }
    }

    private static func preflightTokenizer(modelRoot: URL) throws {
        let required = [
            "tokenizer_config.json",
            "vocab.json",
            "merges.txt"
        ]

        for name in required {
            guard FileManager.default.fileExists(
                atPath: modelRoot.appendingPathComponent(name).path
            ) else {
                throw TuringQwenNativeError.missingModelFile(name)
            }
        }
    }

    private static func validateWeightMap(
        _ index: TuringQwenNativeSafetensorsIndex
    ) throws {
        guard index.tensors.isEmpty == false else {
            throw TuringQwenNativeError.invalidSafetensors("No tensors found in model.safetensors.")
        }

        try index.requireAny(prefixes: [
            "talker."
        ])
    }

    @discardableResult
    private static func withStage<T>(
        _ stage: TuringQwenNativeStage,
        trace: TuringQwenNativeTrace,
        breadcrumbs: TuringQwenNativeStageBreadcrumbs,
        body: () throws -> T
    ) throws -> T {
        breadcrumbs.started(stage)
        trace.stageStarted(stage)
        do {
            let result = try body()
            breadcrumbs.completed(stage)
            trace.stageCompleted(stage)
            return result
        } catch {
            throw error
        }
    }
}

struct TuringQwenNativeVoiceDesignPrompt: Sendable {
    let assistantText: String
    let instructText: String
    let assistantInputIDs: [Int]
    let instructInputIDs: [Int]
}

enum TuringQwenNativeVoiceDesignPromptBuilder {
    static func build(
        text: String,
        voiceDescription: String,
        language: String,
        englishLanguageID: Int?,
        tokenizer: TuringQwenNativeTokenizer
    ) throws -> TuringQwenNativeVoiceDesignPrompt {
        guard text.isEmpty == false else {
            throw TuringQwenNativeError.invalidConfig("VoiceDesign text is empty.")
        }
        guard voiceDescription.isEmpty == false else {
            throw TuringQwenNativeError.invalidConfig("VoiceDesign instruction is empty.")
        }
        guard language.lowercased() == "english",
              englishLanguageID != nil else {
            throw TuringQwenNativeError.invalidConfig("Only english VoiceDesign canary is wired.")
        }

        let assistantText = "<|im_start|>assistant\n\(text)<|im_end|>\n<|im_start|>assistant\n"
        let instructText = "<|im_start|>user\n\(voiceDescription)<|im_end|>\n"

        return TuringQwenNativeVoiceDesignPrompt(
            assistantText: assistantText,
            instructText: instructText,
            assistantInputIDs: try tokenizer.encode(assistantText),
            instructInputIDs: try tokenizer.encode(instructText)
        )
    }
}
