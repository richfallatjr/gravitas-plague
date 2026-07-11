import Foundation

enum TuringVoiceRunResult: Sendable, Equatable {
  case succeeded(String)
  case failed(String)

  var pickerStatus: String {
    switch self {
    case .succeeded(let message):
      return message
    case .failed(let message):
      return "Failed: \(message)"
    }
  }

  var succeeded: Bool {
    if case .succeeded = self {
      return true
    }
    return false
  }
}
