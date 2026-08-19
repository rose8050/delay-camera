import AVFoundation
import Photos
import Combine

/// 카메라의 실시간 입력을 한 곳(captureOutput 델리게이트)에서 받아
/// 서로 절대 간섭하지 않는 두 개의 파이프라인으로 분기시킨다.
///
///   Camera input
///        ├──> Delay buffer ──> delayed preview  (항상 동작, 녹화 상태와 무관)
///        └──> AVAssetWriter ──> saved video file (isRecording == true 인 동안만, 항상 "현재" 프레임을 기록)
///
/// 두 파이프라인은 별도의 상태(delay buffer / writer)를 가지며, 한쪽이 다른 쪽을
/// 멈추거나, 리셋하거나, 값을 바꾸는 일이 없다. 이것이 이 앱의 핵심 불변조건이다.
final class CameraManager: NSObject, ObservableObject {

    // MARK: Published UI state

    @Published var delaySeconds: Double = 30.0
    @Published var isRecording = false
    @Published var errorMessage: String?

    /// 지연 프리뷰를 그리는 레이어. 항상 살아있고, 녹화 여부와 무관하게 계속 업데이트된다.
    let displayLayer = AVSampleBufferDisplayLayer()

    // MARK: Capture session

    private let session = AVCaptureSession()
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let audioDataOutput = AVCaptureAudioDataOutput()

    private let captureQueue = DispatchQueue(label: "camera.capture.queue")

    // MARK: Delay buffer pipeline (파이프라인 #1)

    private struct BufferedFrame {
        let sampleBuffer: CMSampleBuffer
        let captureHostTime: Double // CACurrentMediaTime() 기준, "이 프레임이 실제로 찍힌 시각"
    }

    private var videoDelayBuffer: [BufferedFrame] = []
    private let delayBufferLock = NSLock()
    private let delayQueue = DispatchQueue(label: "camera.delay.queue")
    private var displayTimer: DispatchSourceTimer?

    // MARK: Recording pipeline (파이프라인 #2) — recordingQueue 에서만 접근

    private let recordingQueue = DispatchQueue(label: "camera.recording.queue")
    private var assetWriter: AVAssetWriter?
    private var assetWriterVideoInput: AVAssetWriterInput?
    private var assetWriterAudioInput: AVAssetWriterInput?
    private var recordingStartPTS: CMTime?
    private var writerSessionStarted = false
    /// isRecording(@Published, main-thread 용 UI 미러)과는 별개로, 실제 프레임을
    /// writer에 넣을지 말지는 이 플래그로만 판단한다. recordingQueue에서만 읽고 쓴다.
    private var recordingActive = false

    override init() {
        super.init()
        displayLayer.videoGravity = .resizeAspectFill
    }

    // MARK: - Setup

    func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let videoInput = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(videoInput) else {
            session.commitConfiguration()
            DispatchQueue.main.async { self.errorMessage = "카메라를 열 수 없습니다." }
            return
        }
        session.addInput(videoInput)

        if let mic = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(audioInput) {
            session.addInput(audioInput)
        }

        videoDataOutput.setSampleBufferDelegate(self, queue: captureQueue)
        videoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(videoDataOutput) {
            session.addOutput(videoDataOutput)
        }
        if let connection = videoDataOutput.connection(with: .video), connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }

        audioDataOutput.setSampleBufferDelegate(self, queue: captureQueue)
        if session.canAddOutput(audioDataOutput) {
            session.addOutput(audioDataOutput)
        }

        session.commitConfiguration()
    }

    func startSession() {
        captureQueue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
        }
        startDisplayTimer()
    }

    func stopSession() {
        captureQueue.async { [weak self] in
            self?.session.stopRunning()
        }
        stopDisplayTimer()
    }

    // MARK: - Delay buffer → delayed preview

    /// 30fps 정도로 버퍼를 확인해서, "지금 - delaySeconds" 시점을 지난 가장 오래된
    /// 프레임을 꺼내 화면에 그린다. delay 값이 바뀌어도, 녹화가 시작/종료돼도
    /// 이 루프의 동작 방식 자체는 전혀 바뀌지 않는다.
    private func startDisplayTimer() {
        let timer = DispatchSource.makeTimerSource(queue: delayQueue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 30.0)
        timer.setEventHandler { [weak self] in
            self?.drainDelayBufferIfReady()
        }
        timer.resume()
        displayTimer = timer
    }

    private func stopDisplayTimer() {
        displayTimer?.cancel()
        displayTimer = nil
    }

    private func drainDelayBufferIfReady() {
        let now = CACurrentMediaTime()
        let delay = delaySeconds

        delayBufferLock.lock()
        var ready: [BufferedFrame] = []
        while let first = videoDelayBuffer.first, now - first.captureHostTime >= delay {
            ready.append(videoDelayBuffer.removeFirst())
        }
        // delay 값을 사용자가 갑자기 줄인 경우를 대비한 안전장치: 무한정 쌓이지 않게
        // 버퍼 길이를 (delay + 5초) 로 상한을 둔다. (조회 방식 자체는 바꾸지 않는다)
        let maxAge = delay + 5
        while let first = videoDelayBuffer.first, now - first.captureHostTime > maxAge {
            videoDelayBuffer.removeFirst()
        }
        delayBufferLock.unlock()

        for frame in ready where displayLayer.isReadyForMoreMediaData {
            displayLayer.enqueue(frame.sampleBuffer)
        }
    }

    // MARK: - Recording control (delay buffer에 전혀 손대지 않는다)

    func startRecording() {
        recordingQueue.async { [weak self] in
            guard let self, !self.recordingActive else { return }

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mov")

            guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else {
                DispatchQueue.main.async { self.errorMessage = "녹화 파일을 생성할 수 없습니다." }
                return
            }

            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 1280,
                AVVideoHeightKey: 720
            ]
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput.expectsMediaDataInRealTime = true

            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 44100,
                AVEncoderBitRateKey: 64000
            ]
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioInput.expectsMediaDataInRealTime = true

            if writer.canAdd(videoInput) { writer.add(videoInput) }
            if writer.canAdd(audioInput) { writer.add(audioInput) }

            self.assetWriter = writer
            self.assetWriterVideoInput = videoInput
            self.assetWriterAudioInput = audioInput
            self.writerSessionStarted = false
            self.recordingStartPTS = nil
            self.recordingActive = true

            DispatchQueue.main.async { self.isRecording = true }
        }
    }

    func stopRecording() {
        recordingQueue.async { [weak self] in
            guard let self, self.recordingActive else { return }
            self.recordingActive = false

            let writer = self.assetWriter
            self.assetWriterVideoInput?.markAsFinished()
            self.assetWriterAudioInput?.markAsFinished()

            writer?.finishWriting { [weak self] in
                guard let self else { return }
                DispatchQueue.main.async { self.isRecording = false }
                if writer?.status == .completed, let url = writer?.outputURL {
                    self.saveToPhotoLibrary(url: url)
                } else if let error = writer?.error {
                    DispatchQueue.main.async { self.errorMessage = error.localizedDescription }
                }
            }
        }
    }

    private func saveToPhotoLibrary(url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { self.errorMessage = "사진 라이브러리 접근 권한이 없습니다." }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }, completionHandler: { success, error in
                try? FileManager.default.removeItem(at: url)
                if !success {
                    DispatchQueue.main.async { self.errorMessage = error?.localizedDescription ?? "저장 실패" }
                }
            })
        }
    }
}

// MARK: - 카메라의 실시간 프레임이 들어오는 단 하나의 지점.
// 여기서 delay buffer / recorder 두 파이프라인으로 각각 독립적으로 분기(fork)한다.
extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let isVideo = (output === videoDataOutput)

        // 1) Delay buffer 파이프라인: 항상 쌓는다. 녹화 중이든 아니든 동일하게 동작한다.
        if isVideo {
            let hostTime = CACurrentMediaTime()
            delayBufferLock.lock()
            videoDelayBuffer.append(BufferedFrame(sampleBuffer: sampleBuffer, captureHostTime: hostTime))
            delayBufferLock.unlock()
        }

        // 2) Recording 파이프라인: 녹화 중일 때만, 지금 들어온 "현재" 프레임을 그대로 기록한다.
        //    delay buffer를 거치지 않고 captureOutput에서 바로 분기되므로 지연의 영향을 받지 않는다.
        recordingQueue.async { [weak self] in
            self?.appendToWriterIfRecording(sampleBuffer: sampleBuffer, isVideo: isVideo)
        }
    }

    private func appendToWriterIfRecording(sampleBuffer: CMSampleBuffer, isVideo: Bool) {
        guard recordingActive, let writer = assetWriter else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if !writerSessionStarted {
            guard isVideo else { return } // 비디오 프레임 기준으로 세션을 시작한다 (오디오가 먼저 도착하면 대기)
            writer.startWriting()
            writer.startSession(atSourceTime: pts)
            writerSessionStarted = true
            recordingStartPTS = pts
        }

        guard let start = recordingStartPTS, pts >= start else { return }

        if isVideo {
            if assetWriterVideoInput?.isReadyForMoreMediaData == true {
                assetWriterVideoInput?.append(sampleBuffer)
            }
        } else {
            if assetWriterAudioInput?.isReadyForMoreMediaData == true {
                assetWriterAudioInput?.append(sampleBuffer)
            }
        }
    }
}
