import Foundation
import MLX

struct TuringQwenNativeSampledToken {
  let tokenArray: MLXArray
  let tokenIDForStopCheck: Int?
  let candidateCount: Int
  let materializationSeconds: Double
  let hostSelectionSeconds: Double
}

enum TuringQwenNativeSampler {
  static func select(
    logits: MLXArray,
    configuration:
      TuringQwenNativeTokenSamplerConfiguration,
    generatedTokenHistory: [Int],
    randomDraw: Double?,
    needHostTokenID: Bool,
    vocabSize: Int
  ) throws -> TuringQwenNativeSampledToken {
    try configuration.validate(
      stage: "token"
    )

    guard logits.shape == [1, 1, vocabSize] else {
      throw
        TuringQwenNativeSamplingError
        .invalidLogitsShape(
          expected: [1, 1, vocabSize],
          actual: logits.shape
        )
    }

    switch configuration.mode {
    case .greedy:
      let tokenArray =
        greedyTokenArray(from: logits)
      let tokenID =
        needHostTokenID
        ? tokenArray.item(Int.self)
        : nil

      return TuringQwenNativeSampledToken(
        tokenArray: tokenArray,
        tokenIDForStopCheck: tokenID,
        candidateCount: 1,
        materializationSeconds: 0,
        hostSelectionSeconds: 0
      )

    case .temperatureTopP:
      guard let randomDraw else {
        throw
          TuringQwenNativeSamplingError
          .invalidConfiguration(
            "Sampled decoding requires a request-local random draw."
          )
      }

      guard randomDraw >= 0,
        randomDraw < 1
      else {
        throw
          TuringQwenNativeSamplingError
          .invalidRandomDraw(
            randomDraw
          )
      }

      // Deliberate safety boundary:
      //
      // 1. Materialize exactly one logits vector.
      // 2. Transfer plain Float values.
      // 3. Perform top-k, penalties, top-p, and random selection on the
      //    host.
      // 4. Return one scalar constant MLXArray.
      //
      // No MLXRandom state, categorical op, full-vocabulary mask, or
      // sampling graph survives into the next autoregressive step.
      let materializationStart = Date()
      let vector =
        logits[0, 0].asType(.float32)
      try checkedEval(vector)
      let hostLogits =
        vector.asArray(Float.self)
      let materializationSeconds =
        Date().timeIntervalSince(
          materializationStart
        )

      let hostStart = Date()
      let tokenID =
        try sampleMaterializedLogits(
          hostLogits,
          configuration:
            configuration,
          generatedTokenHistory:
            generatedTokenHistory,
          randomDraw: randomDraw
        )
      let hostSeconds =
        Date().timeIntervalSince(
          hostStart
        )

      return TuringQwenNativeSampledToken(
        tokenArray:
          MLXArray([tokenID]),
        tokenIDForStopCheck:
          tokenID,
        candidateCount:
          candidateBudget(
            vocabSize:
              hostLogits.count,
            topK:
              configuration.topK,
            generatedTokenHistory:
              generatedTokenHistory
          ),
        materializationSeconds:
          materializationSeconds,
        hostSelectionSeconds:
          hostSeconds
      )
    }
  }

  static func greedyTokenArray(
    from logits: MLXArray
  ) -> MLXArray {
    logits[0, 0].argMax(
      keepDims: true
    )
  }

  static func greedyToken(
    from logits: MLXArray
  ) throws -> Int {
    greedyTokenArray(
      from: logits
    ).item(Int.self)
  }

  static func candidateBudget(
    vocabSize: Int,
    topK: Int,
    generatedTokenHistory: [Int]
  ) -> Int {
    let repeatedCount = Set(
      generatedTokenHistory.filter {
        $0 >= 0 && $0 < vocabSize
      }
    ).count

    // Repetition penalty >= 1 can only lower a repeated token's score.
    // K + R original candidates are sufficient to recover the exact final
    // top K after at most R repeated candidates are demoted.
    return min(
      vocabSize,
      max(1, topK) + repeatedCount
    )
  }

  static func sampleMaterializedLogits(
    _ logits: [Float],
    configuration:
      TuringQwenNativeTokenSamplerConfiguration,
    generatedTokenHistory: [Int],
    randomDraw: Double
  ) throws -> Int {
    guard randomDraw >= 0,
      randomDraw < 1
    else {
      throw
        TuringQwenNativeSamplingError
        .invalidRandomDraw(
          randomDraw
        )
    }

    guard logits.isEmpty == false else {
      throw TuringQwenNativeSamplingError
        .noFiniteCandidates
    }

    let budget = candidateBudget(
      vocabSize: logits.count,
      topK: configuration.topK,
      generatedTokenHistory:
        generatedTokenHistory
    )

    var candidates = topCandidates(
      logits: logits,
      count: budget
    )

    guard candidates.isEmpty == false else {
      throw TuringQwenNativeSamplingError
        .noFiniteCandidates
    }

    let repeated =
      Set(generatedTokenHistory)

    for index in candidates.indices {
      var value =
        candidates[index].logit

      if repeated.contains(
        candidates[index].tokenID
      ),
        configuration
          .repetitionPenalty > 1
      {
        value =
          value < 0
          ? value
            * configuration
            .repetitionPenalty
          : value
            / configuration
            .repetitionPenalty
      }

      candidates[index].logit =
        value
        / configuration.temperature
    }

    candidates.sort(
      by: descendingCandidateOrder
    )

    if candidates.count > configuration.topK {
      candidates.removeSubrange(
        configuration.topK..<candidates.count
      )
    }

    guard
      let maximum =
        candidates
        .map(\.logit)
        .filter(\.isFinite)
        .max()
    else {
      throw TuringQwenNativeSamplingError
        .noFiniteCandidates
    }

    var weighted: [(candidate: Candidate, weight: Double)] =
      candidates.compactMap {
        candidate in

        guard
          candidate.logit
            .isFinite
        else {
          return nil
        }

        let weight = Foundation.exp(
          Double(
            candidate.logit
              - maximum
          )
        )

        guard weight.isFinite,
          weight > 0
        else {
          return nil
        }

        return (
          candidate,
          weight
        )
      }

    guard weighted.isEmpty == false else {
      throw TuringQwenNativeSamplingError
        .noFiniteCandidates
    }

    let fullWeight =
      weighted.reduce(0) {
        $0 + $1.weight
      }

    guard fullWeight.isFinite,
      fullWeight > 0
    else {
      throw TuringQwenNativeSamplingError
        .noFiniteCandidates
    }

    if configuration.topP < 1 {
      var cumulative = 0.0
      var kept: [(candidate: Candidate, weight: Double)] =
        []

      for item in weighted {
        kept.append(item)
        cumulative +=
          item.weight
          / fullWeight

        if cumulative
          >= Double(
            configuration.topP
          )
        {
          break
        }
      }

      weighted = kept
    }

    let selectedWeight =
      weighted.reduce(0) {
        $0 + $1.weight
      }
    var threshold =
      randomDraw * selectedWeight

    for item in weighted {
      threshold -= item.weight
      if threshold <= 0 {
        return item.candidate
          .tokenID
      }
    }

    // Floating-point rounding can leave a tiny positive remainder.
    return weighted[
      weighted.index(
        before:
          weighted.endIndex
      )
    ].candidate.tokenID
  }

  private struct Candidate {
    let tokenID: Int
    var logit: Float
  }

  private static func topCandidates(
    logits: [Float],
    count: Int
  ) -> [Candidate] {
    guard count > 0 else {
      return []
    }

    var heap: [Candidate] = []
    heap.reserveCapacity(count)

    for (
      tokenID,
      logit
    ) in logits.enumerated() {
      guard logit.isFinite else {
        continue
      }

      let candidate = Candidate(
        tokenID: tokenID,
        logit: logit
      )

      if heap.count < count {
        heap.append(candidate)
        siftUpMinHeap(
          &heap,
          from:
            heap.count - 1
        )
        continue
      }

      guard
        isBetter(
          candidate,
          than: heap[0]
        )
      else {
        continue
      }

      heap[0] = candidate
      siftDownMinHeap(
        &heap,
        from: 0
      )
    }

    return heap
  }

  private static func isBetter(
    _ lhs: Candidate,
    than rhs: Candidate
  ) -> Bool {
    if lhs.logit != rhs.logit {
      return lhs.logit > rhs.logit
    }

    // Stable deterministic tie-break.
    return lhs.tokenID < rhs.tokenID
  }

  private static func isWorse(
    _ lhs: Candidate,
    than rhs: Candidate
  ) -> Bool {
    if lhs.logit != rhs.logit {
      return lhs.logit < rhs.logit
    }

    return lhs.tokenID > rhs.tokenID
  }

  private static func descendingCandidateOrder(
    _ lhs: Candidate,
    _ rhs: Candidate
  ) -> Bool {
    isBetter(lhs, than: rhs)
  }

  private static func siftUpMinHeap(
    _ heap: inout [Candidate],
    from startIndex: Int
  ) {
    var child = startIndex

    while child > 0 {
      let parent =
        (child - 1) / 2

      guard
        isWorse(
          heap[child],
          than: heap[parent]
        )
      else {
        return
      }

      heap.swapAt(
        child,
        parent
      )
      child = parent
    }
  }

  private static func siftDownMinHeap(
    _ heap: inout [Candidate],
    from startIndex: Int
  ) {
    var parent = startIndex

    while true {
      let left =
        parent * 2 + 1
      let right = left + 1
      var worst = parent

      if left < heap.count,
        isWorse(
          heap[left],
          than: heap[worst]
        )
      {
        worst = left
      }

      if right < heap.count,
        isWorse(
          heap[right],
          than: heap[worst]
        )
      {
        worst = right
      }

      guard worst != parent else {
        return
      }

      heap.swapAt(
        parent,
        worst
      )
      parent = worst
    }
  }
}
