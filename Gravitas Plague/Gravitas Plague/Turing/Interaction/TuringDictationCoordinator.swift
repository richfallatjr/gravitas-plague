import AVFoundation
import Combine
import Foundation
import Speech

@MainActor
final class TuringDictationCoordinator: ObservableObject {
    enum Status: Equatable {
        case idle
        case requestingPermission
        case recording
        case finishing
        case failed(String)
    }

    @Published private(set) var isRecording = false
    @Published private(set) var partialTranscript = ""
    @Published private(set) var finalTranscript = ""
    @Published private(set) var status: Status = .idle

    var onEvent: ((TuringDictationEvent) -> Void)?

    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?

    func beginHoldToRecord() async {
        guard !isRecording else {
            return
        }

        status = .requestingPermission

        do {
            try await requestPermissions()
            try Task.checkCancellation()
            onEvent?(.recordingStarted)
            try startRecognition()
            try Task.checkCancellation()
            print("[TuringDictation] recording started")
        } catch is CancellationError {
            await cancel(reason: "press ended before recording started")
        } catch {
            await cancel(reason: error.localizedDescription)
            status = .failed(error.localizedDescription)
            onEvent?(.failed(error.localizedDescription))
            print("""
            [TuringDictation] recording failed
              error: \(error.localizedDescription)
            """)
        }
    }

    func endHoldToSend() async throws -> String {
        guard isRecording else {
            let transcript = bestTranscript()
            guard transcript.isEmpty == false else {
                throw TuringRuntimeError.foundationJSONGateFailed(
                    "Dictation ended without transcript."
                )
            }
            return transcript
        }

        status = .finishing
        tearDownAudioEngine()
        recognitionRequest?.endAudio()

        try? await Task.sleep(nanoseconds: 300_000_000)

        let transcript = bestTranscript()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        isRecording = false

        guard transcript.isEmpty == false else {
            status = .failed("No speech recognized.")
            throw TuringRuntimeError.foundationJSONGateFailed(
                "No speech recognized."
            )
        }

        finalTranscript = transcript
        status = .idle
        onEvent?(.finalTranscript(transcript))

        print("""
        [TuringDictation] recording finished
          finalTranscript: \(transcript)
        """)

        return transcript
    }

    func cancel(reason: String) async {
        tearDownAudioEngine()
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        isRecording = false
        status = .idle
        onEvent?(.cancelled)

        print("""
        [TuringDictation] recording cancelled
          reason: \(reason)
        """)
    }

    private func requestPermissions() async throws {
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }

        guard speechStatus == .authorized else {
            throw TuringRuntimeError.foundationUnavailable
        }

#if os(iOS) || os(visionOS) || os(tvOS)
        let microphoneAllowed = await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { allowed in
                continuation.resume(returning: allowed)
            }
        }

        guard microphoneAllowed else {
            throw TuringRuntimeError.playbackFailed(
                "Microphone permission denied."
            )
        }
#endif
    }

    private func startRecognition() throws {
        partialTranscript = ""
        finalTranscript = ""

        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        tearDownAudioEngine()
        try configureAudioSessionForRecording()

        print("[TuringDictation] audio session configured for recording")

        let recognizer = SFSpeechRecognizer(
            locale: Locale(identifier: "en_US")
        )
        guard let recognizer, recognizer.isAvailable else {
            throw TuringRuntimeError.foundationUnavailable
        }
        self.recognizer = recognizer

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let audioEngine = AVAudioEngine()
        self.audioEngine = audioEngine
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: format
        ) { [weak request] buffer, _ in
            request?.append(buffer)
        }

        audioEngine.prepare()
        print("[TuringDictation] audio engine starting")
        try audioEngine.start()
        isRecording = true
        status = .recording

        recognitionTask = recognizer.recognitionTask(
            with: request
        ) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }

                if let result {
                    let transcript = result.bestTranscription.formattedString
                    self.partialTranscript = transcript
                    self.onEvent?(.partialTranscript(transcript))
                    if result.isFinal {
                        self.finalTranscript = transcript
                    }
                    print("""
                    [TuringDictation] partial transcript updated
                      text: \(transcript)
                    """)
                }

                if let error {
                    self.status = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func stopAudioCapture() {
        guard let audioEngine else {
            return
        }

        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        print("[TuringDictation] audio engine stopped")
    }

    private func tearDownAudioEngine() {
        stopAudioCapture()
        audioEngine?.reset()
        audioEngine = nil
    }

    private func configureAudioSessionForRecording() throws {
#if os(iOS) || os(visionOS) || os(tvOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .spokenAudio,
            options: [
                .defaultToSpeaker,
                .allowBluetooth,
                .mixWithOthers
            ]
        )
        try session.setActive(true, options: [])
#endif
    }

    private func bestTranscript() -> String {
        let final = finalTranscript.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if !final.isEmpty {
            return final
        }

        return partialTranscript.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
    }
}
