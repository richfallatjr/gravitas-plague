import Foundation

#if canImport(MLX)
import MLX
#endif

actor TuringQwenTransientCleanup {
    func releaseTransientState(reason: String) async {
        print(
            """
            [TuringTTS] Qwen transient cleanup starting
              reason: \(reason)
            """
        )

        TuringMLXCacheCleaner.clearIfAvailable(reason: reason)

        print(
            """
            [TuringTTS] Qwen transient cleanup finished
              reason: \(reason)
            """
        )
    }
}

enum TuringMLXCacheCleaner {
    static func clearIfAvailable(reason: String) {
        #if canImport(MLX)
        Memory.clearCache()
        print(
            """
            [TuringTTS] MLX cache cleared
              reason: \(reason)
            """
        )
        #else
        print(
            """
            [TuringTTS] MLX explicit cache clear unavailable in linked package
              reason: \(reason)
            """
        )
        #endif
    }
}
