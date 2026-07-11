import Foundation

actor TuringQwenCharacterPoolArbiter {
  static let shared = TuringQwenCharacterPoolArbiter()

  private struct Waiter {
    let owner: String
    let continuation: CheckedContinuation<Void, Never>
  }

  private var currentOwner: String?
  private var waiters: [Waiter] = []

  func acquire(owner: String) async {
    if currentOwner == nil {
      currentOwner = owner
      print(
        """
        [TuringQwenCharacterPool] acquired
          owner: \(owner)
          queuedOwners: 0
        """)
      return
    }

    print(
      """
      [TuringQwenCharacterPool] queued
        owner: \(owner)
        currentOwner: \(currentOwner ?? "none")
        queuedOwnersBeforeAppend: \(waiters.count)
      """)

    await withCheckedContinuation { continuation in
      waiters.append(
        Waiter(
          owner: owner,
          continuation: continuation
        )
      )
    }

    print(
      """
      [TuringQwenCharacterPool] acquired
        owner: \(owner)
        queuedOwners: \(waiters.count)
      """)
  }

  func release(owner: String) {
    guard currentOwner == owner else {
      assertionFailure(
        "Qwen character pool release owner mismatch. "
          + "Expected \(currentOwner ?? "none"), got \(owner)."
      )
      return
    }

    if waiters.isEmpty {
      currentOwner = nil
      print(
        """
        [TuringQwenCharacterPool] released
          owner: \(owner)
          nextOwner: none
        """)
      return
    }

    let next = waiters.removeFirst()
    currentOwner = next.owner

    print(
      """
      [TuringQwenCharacterPool] released
        owner: \(owner)
        nextOwner: \(next.owner)
      """)

    next.continuation.resume()
  }
}
