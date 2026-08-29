import AVFoundation
import Foundation

private enum ProbeFailure: Error, CustomStringConvertible {
    case usage
    case invalidOutputPath(String)
    case formatCreation
    case conversion(String)

    var description: String {
        switch self {
        case .usage:
            return "usage: mind-eye-audio-timeline-probe <audio> [--output-wav <.build/path.wav>]"
        case .invalidOutputPath(let path):
            return "optional output must be a WAV under a .build directory: \(path)"
        case .formatCreation:
            return "could not create the fixed 48 kHz mono PCM16 format"
        case .conversion(let message):
            return "AVAudioConverter failed: \(message)"
        }
    }
}

private func jsonString(_ value: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: [value])
    let encoded = String(data: data, encoding: .utf8)!
    return String(encoded.dropFirst().dropLast())
}

private func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count == 1 || (arguments.count == 3 && arguments[1] == "--output-wav") else {
        throw ProbeFailure.usage
    }
    let sourceURL = URL(fileURLWithPath: arguments[0]).standardizedFileURL
    let outputURL: URL?
    if arguments.count == 3 {
        let candidate = URL(fileURLWithPath: arguments[2]).standardizedFileURL
        guard candidate.pathExtension.lowercased() == "wav",
              candidate.pathComponents.contains(".build") else {
            throw ProbeFailure.invalidOutputPath(candidate.path)
        }
        try FileManager.default.createDirectory(
            at: candidate.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        outputURL = candidate
    } else {
        outputURL = nil
    }

    let source = try AVAudioFile(forReading: sourceURL)
    guard let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 48_000,
        channels: 1,
        interleaved: true
    ), let converter = AVAudioConverter(from: source.processingFormat, to: outputFormat) else {
        throw ProbeFailure.formatCreation
    }
    let outputFile = try outputURL.map {
        try AVAudioFile(forWriting: $0, settings: outputFormat.settings)
    }
    var inputEnded = false
    var decodedFrames: AVAudioFramePosition = 0
    var iterations = 0
    while true {
        iterations += 1
        guard iterations < 1_000_000 else {
            throw ProbeFailure.conversion("conversion made no bounded progress")
        }
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4_096) else {
            throw ProbeFailure.formatCreation
        }
        var conversionError: NSError?
        var inputError: Error?
        var suppliedInput = false
        let status = converter.convert(to: output, error: &conversionError) { packetCount, inputStatus in
            if inputEnded {
                inputStatus.pointee = .endOfStream
                return nil
            }
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            guard let input = AVAudioPCMBuffer(
                pcmFormat: source.processingFormat,
                frameCapacity: max(4_096, packetCount)
            ) else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            do {
                try source.read(into: input, frameCount: min(input.frameCapacity, max(4_096, packetCount)))
            } catch let error as NSError where error.code == -39 {
                inputEnded = true
                inputStatus.pointee = .endOfStream
                return nil
            } catch {
                inputError = error
                inputStatus.pointee = .noDataNow
                return nil
            }
            if input.frameLength == 0 {
                inputEnded = true
                inputStatus.pointee = .endOfStream
                return nil
            }
            inputStatus.pointee = .haveData
            return input
        }
        if let conversionError {
            throw ProbeFailure.conversion(conversionError.localizedDescription)
        }
        if let inputError {
            throw ProbeFailure.conversion(inputError.localizedDescription)
        }
        if output.frameLength > 0 {
            decodedFrames += AVAudioFramePosition(output.frameLength)
            try outputFile?.write(from: output)
        }
        let finished = status == .endOfStream ||
            (status == .inputRanDry && inputEnded && output.frameLength == 0)
        if finished {
            let sourceRate = source.processingFormat.sampleRate
            print("{")
            print("  \"schemaVersion\": 1,")
            print("  \"sourceSampleRate\": \(String(format: "%.9f", sourceRate)),")
            print("  \"sourceFrameLength\": \(source.length),")
            print("  \"decodedSampleRate\": 48000,")
            print("  \"decodedSampleCount\": \(decodedFrames),")
            print("  \"decodedChannels\": 1")
            print("}")
            return
        }
        switch status {
        case .error:
            throw ProbeFailure.conversion("converter returned error")
        case .haveData, .inputRanDry:
            continue
        case .endOfStream:
            return
        @unknown default:
            throw ProbeFailure.conversion("unknown converter status")
        }
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
