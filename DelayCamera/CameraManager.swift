import AVFoundation
import CoreMedia
import VideoToolbox
import QuartzCore
import Photos
import Combine

/// 카메라의 실시간 입력을 받아 처리한다.
///
///   Camera input (후면 카메라 고정, portrait, 720x1280 @ 60fps)
///        ├─ video ──> H.264 압축(VTCompressionSession) ──> 지연 링버퍼 ──(N초 후 drain)──┬──> displayLayer (항상)
///        │                                                                              └──> AVAssetWriter video (녹화 중일 때만, passthrough — 재인코딩 없음)
///        └─ audio ──> 원본 그대로 ──> 지연 링버퍼 ──(같은 N초 기준 drain)──> AVAssetWriter audio (녹화 중일 때만, AAC로 트랜스코드)
///
/// 녹화 파이프라인은 대기 큐 + requestMediaDataWhenReady 패턴을 쓴다: writer가 순간적으로
/// "아직 준비 안 됨" 상태여도 샘플을 버리지 않고 큐에 쌓아뒀다가, 준비되는 즉시 흘려보낸다.
final class CameraManager: NSObject, ObservableObject {

    // MARK: Published UI state

    static let delayPresets: [Double] = [15, 20, 30, 40]

    @Published private(set) var delaySeconds: Double = 30
    @Published var isRecording = false
    @Published private(set) var recordingStartDate: Date?
    @Published var errorMessage: String?

    let displayLayer = AVSampleBufferDisplayLayer()

    // MARK: Capture session

    private let session = AVCaptureSession()
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let audioDataOutput = AVCaptureAudioDataOutput()

    private let captureQueue = DispatchQueue(label: "camera.capture.queue")

    private static let sensorWidth: Int32 = 1280
    private static let sensorHeight: Int32 = 720
    private static let targetFPS: Double = 60

    private var discoveredFrameWidth: Int32?
    private var discoveredFrameHeight: Int32?

    // MARK: Delay buffer

    private struct BufferedVideoFrame {
        let sampleBuffer: CMSampleBuffer
        let captureHostTime: Double
    }
    private struct BufferedAudioFrame {
        let sampleBuffer: CMSampleBuffer
        let captureHostTime: Double
    }

    private var videoDelayBuffer: [BufferedVideoFrame] = []
    private let videoDelayBufferLock = NSLock()

    private var audioDelayBuffer: [BufferedAudioFrame] = []
    private let audioDelayBufferLock = NSLock()

    private var displayLink: CADisplayLink?

    private var compressionSession: VTCompressionSession?

    // MARK: Recording — recordingQueue 에서만 접근

    private let recordingQueue = DispatchQueue(label: "camera.recording.queue")
    private var assetWriter: AVAssetWriter?
    private var assetWriterVideoInput: AVAssetWriterInput?
    private var assetWriterAudioInput: AVAssetWriterInput?
    private var recordingStartPTS: CMTime?
    private var writerSessionStarted = false
    private var recordingActive = false

    /// writer가 순간적으로 안 준비된 상태여도 샘플을 잃지 않기 위한 대기 큐.
    /// requestMediaDataWhenReady 콜백과 append 직후 모두 recordingQueue에서만 건드린다.
    private var pendingVideoSamples: [CMSampleBuffer] = []
    private var pendingAudioSamples: [CMSampleBuffer] = []
    /// 정말 writer가 멈춰버린 극단적 상황(디스크 오류 등)에 대비한 방어적 상한.
    private static let maxPendingSamples = 500

    private var debugAudioAppended = 0
    private var debugAudioDropped = 0

    override init() {
        super.init()
        displayLayer.videoGravity = .resizeAspectFill
        displayLayer.transform = CATransform3DIdentity
    }

    deinit {
        displayLink?.invalidate()
        if let compressionSession {
            VTCompressionSessionInvalidate(compressionSession)
        }
    }

    // MARK: - Setup

    func configureSession() {
        configureAudioSession()

        session.beginConfiguration()
        session.automaticallyConfiguresApplicationAudioSession = true
        session.sessionPreset = .hd1280x720

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let videoInput = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(videoInput) else {
            session.commitConfiguration()
            DispatchQueue.main.async { self.errorMessage = "카메라를 열 수 없습니다." }
            return
        }
        session.addInput(videoInput)
        applyHighFrameRateFormat(to: camera)
        session.sessionPreset = .inputPriority

        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            addAudioInput()
        }

        videoDataOutput.setSampleBufferDelegate(self, queue: captureQueue)
        videoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(videoDataOutput) {
            session.addOutput(videoDataOutput)
        }
        configureVideoConnection()

        audioDataOutput.setSampleBufferDelegate(self, queue: captureQueue)
        if session.canAddOutput(audioDataOutput) {
            session.addOutput(audioDataOutput)
        }

        session.commitConfiguration()

        handleAudioAuthorizationIfNeeded()
    }

    private func configureAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
        } catch {
            DispatchQueue.main.async {
                self.errorMessage = "오디오 세션 설정에 실패했습니다: \(error.localizedDescription)"
            }
        }
    }

    private func handleAudioAuthorizationIfNeeded() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                guard let self else { return }
                guard granted else {
                    DispatchQueue.main.async {
                        self.errorMessage = "마이크 접근 권한이 거부되어 오디오가 녹음되지 않습니다."
                    }
                    return
                }
                self.session.beginConfiguration()
                self.addAudioInput()
                self.session.commitConfiguration()
            }
        case .denied, .restricted:
            DispatchQueue.main.async {
                self.errorMessage = "마이크 접근 권한이 거부되어 오디오가 녹음되지 않습니다. 설정 앱에서 권한을 허용해주세요."
            }
        @unknown default:
            break
        }
    }

    private func addAudioInput() {
        guard let mic = AVCaptureDevice.default(for: .audio),
              let audioInput = try? AVCaptureDeviceInput(device: mic) else {
            DispatchQueue.main.async { self.errorMessage = "마이크를 열 수 없습니다." }
            return
        }
        guard session.canAddInput(audioInput) else {
            DispatchQueue.main.async { self.errorMessage = "오디오 입력을 세션에 추가할 수 없습니다." }
            return
        }
        session.addInput(audioInput)
    }

    private func applyHighFrameRateFormat(to device: AVCaptureDevice) {
        let candidates = device.formats.filter { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return dims.width == Self.sensorWidth && dims.height == Self.sensorHeight
        }
        guard let format = candidates.first(where: { $0.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= Self.targetFPS } })
            ?? candidates.first else { return }

        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            let maxSupportedFPS = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30
            let fps = min(Self.targetFPS, maxSupportedFPS)
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: Int32(fps))
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: Int32(fps))
            device.unlockForConfiguration()
        } catch {
            // 실패해도 세션의 기본 포맷으로 계속 동작한다.
        }
    }

    private func configureVideoConnection() {
        guard let connection = videoDataOutput.connection(with: .video) else { return }
        guard connection.isVideoOrientationSupported else {
            DispatchQueue.main.async { self.errorMessage = "이 기기에서는 세로 방향 고정을 지원하지 않습니다." }
            return
        }
        connection.videoOrientation = .portrait
    }

    private func setupCompressionSession(width: Int32, height: Int32) {
        var newSession: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &newSession
        )

        guard status == noErr, let compressionSession = newSession else {
            DispatchQueue.main.async { self.errorMessage = "지연 프리뷰 인코더 초기화에 실패했습니다." }
            return
        }

        VTSessionSetProperty(compressionSession, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(compressionSession, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(compressionSession, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(compressionSession, key: kVTCompressionPropertyKey_AverageBitRate, value: 12_000_000 as CFTypeRef)
        VTSessionSetProperty(compressionSession, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: Self.targetFPS as CFTypeRef)
        VTSessionSetProperty(compressionSession, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: Int(Self.targetFPS) as CFTypeRef)
        VTCompressionSessionPrepareToEncodeFrames(compressionSession)

        self.compressionSession = compressionSession
    }

    func startSession() {
        captureQueue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
        }
        startDisplayLink()
    }

    func stopSession() {
        captureQueue.async { [weak self] in
            self?.session.stopRunning()
        }
        stopDisplayLink()
    }

    // MARK: - 백그라운드 ↔ 포그라운드 전환

    func handleWillResignActive() {
        if isRecording {
            stopRecording()
        }

        stopDisplayLink()

        captureQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
            if let compressionSession = self.compressionSession {
                VTCompressionSessionInvalidate(compressionSession)
            }
            self.compressionSession = nil
            self.discoveredFrameWidth = nil
            self.discoveredFrameHeight = nil
        }

        videoDelayBufferLock.lock()
        videoDelayBuffer.removeAll()
        videoDelayBufferLock.unlock()

        audioDelayBufferLock.lock()
        audioDelayBuffer.removeAll()
        audioDelayBufferLock.unlock()
    }

    func handleDidBecomeActive() {
        recoverDisplayLayerIfNeeded()

        captureQueue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
        }
        startDisplayLink()
    }

    private func recoverDisplayLayerIfNeeded() {
        if displayLayer.status == .failed {
            displayLayer.flushAndRemoveImage()
        }
    }

    // MARK: - 지연 시간 제어

    func setDelay(_ seconds: Double) {
        guard Self.delayPresets.contains(seconds) else { return }
        delaySeconds = seconds
    }

    // MARK: - Delay buffer → delayed preview (+ 녹화 중이면 같은 프레임을 recording에도 전달)

    private func startDisplayLink() {
        let link = CADisplayLink(target: self, selector: #selector(handleDisplayLink))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func handleDisplayLink() {
        drainDelayBufferIfReady()
    }

    private func drainDelayBufferIfReady() {
        recoverDisplayLayerIfNeeded()

        let now = CACurrentMediaTime()
        let delay = delaySeconds

        videoDelayBufferLock.lock()
        var videoDueCount = 0
        for frame in videoDelayBuffer {
            guard now - frame.captureHostTime >= delay else { break }
            videoDueCount += 1
        }
        let dueVideoFrames = videoDueCount > 0 ? Array(videoDelayBuffer[0..<videoDueCount]) : []
        if videoDueCount > 0 { videoDelayBuffer.removeFirst(videoDueCount) }
        videoDelayBufferLock.unlock()

        for frame in dueVideoFrames {
            recordingQueue.async { [weak self] in
                self?.appendDelayedVideoIfRecording(frame.sampleBuffer)
            }
            if displayLayer.isReadyForMoreMediaData {
                markForImmediateDisplay(frame.sampleBuffer)
                displayLayer.enqueue(frame.sampleBuffer)
            }
        }

        // 오디오는 비디오보다 훨씬 촘촘하게 들어오므로, 이 틱까지 밀린 것을 전부(개수 제한 없이) 꺼낸다.
        audioDelayBufferLock.lock()
        var audioDueCount = 0
        for frame in audioDelayBuffer {
            guard now - frame.captureHostTime >= delay else { break }
            audioDueCount += 1
        }
        let dueAudioFrames = audioDueCount > 0 ? Array(audioDelayBuffer[0..<audioDueCount]) : []
        if audioDueCount > 0 { audioDelayBuffer.removeFirst(audioDueCount) }
        audioDelayBufferLock.unlock()

        for frame in dueAudioFrames {
            recordingQueue.async { [weak self] in
                self?.appendDelayedAudioIfRecording(frame.sampleBuffer)
            }
        }
    }

    private func markForImmediateDisplay(_ sampleBuffer: CMSampleBuffer) {
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
              CFArrayGetCount(attachmentsArray) > 0 else { return }
        let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachmentsArray, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(
            dictionary,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
    }

    private func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else {
            return true
        }
        let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        return !notSync
    }

    // MARK: - Recording control

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

            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 44_100,
                AVEncoderBitRateKey: 96_000
            ]
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings, sourceFormatHint: nil)
            audioInput.expectsMediaDataInRealTime = true

            self.assetWriter = writer
            self.assetWriterVideoInput = nil
            self.assetWriterAudioInput = audioInput
            self.writerSessionStarted = false
            self.recordingStartPTS = nil
            self.recordingActive = true
            self.pendingVideoSamples.removeAll()
            self.pendingAudioSamples.removeAll()
            self.debugAudioAppended = 0
            self.debugAudioDropped = 0

            DispatchQueue.main.async {
                self.isRecording = true
                self.recordingStartDate = Date()
            }
        }
    }

    func stopRecording() {
        recordingQueue.async { [weak self] in
            guard let self, self.recordingActive else { return }
            self.recordingActive = false

            guard self.writerSessionStarted, let writer = self.assetWriter else {
                self.assetWriter = nil
                self.assetWriterVideoInput = nil
                self.assetWriterAudioInput = nil
                self.pendingVideoSamples.removeAll()
                self.pendingAudioSamples.removeAll()
                DispatchQueue.main.async {
                    self.isRecording = false
                    self.recordingStartDate = nil
                    self.errorMessage = "녹화 시간이 너무 짧아 저장할 프레임이 없습니다."
                }
                return
            }

            // 남은 대기 큐를 writer가 받아줄 수 있을 때까지 마저 흘려보낸다.
            self.pumpPendingVideo()
            self.pumpPendingAudio()

            self.assetWriterVideoInput?.markAsFinished()
            self.assetWriterAudioInput?.markAsFinished()

            let appended = self.debugAudioAppended
            let dropped = self.debugAudioDropped

            writer.finishWriting { [weak self] in
                guard let self else { return }
                print("[DelayCamera] 녹화 종료 — 오디오 프레임 기록: \(appended), drop: \(dropped), writer.status: \(writer.status.rawValue), error: \(writer.error?.localizedDescription ?? "없음")")
                DispatchQueue.main.async {
                    self.isRecording = false
                    self.recordingStartDate = nil
                }
                if writer.status == .completed {
                    self.saveToPhotoLibrary(url: writer.outputURL)
                } else if let error = writer.error {
                    DispatchQueue.main.async { self.errorMessage = error.localizedDescription }
                }
            }
        }
    }

    private func appendDelayedVideoIfRecording(_ sampleBuffer: CMSampleBuffer) {
        guard recordingActive, let writer = assetWriter else { return }

        if !writerSessionStarted {
            guard isKeyframe(sampleBuffer),
                  let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }

            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: formatDescription)
            videoInput.expectsMediaDataInRealTime = true
            videoInput.transform = .identity
            guard writer.canAdd(videoInput) else { return }
            writer.add(videoInput)
            assetWriterVideoInput = videoInput
            videoInput.requestMediaDataWhenReady(on: recordingQueue) { [weak self] in
                self?.pumpPendingVideo()
            }

            if let audioInput = assetWriterAudioInput, writer.canAdd(audioInput) {
                writer.add(audioInput)
                audioInput.requestMediaDataWhenReady(on: recordingQueue) { [weak self] in
                    self?.pumpPendingAudio()
                }
            } else {
                print("[DelayCamera] 오디오 input을 writer에 추가하지 못함 (canAdd == false)")
                DispatchQueue.main.async { self.errorMessage = "오디오 트랙을 녹화에 추가하지 못했습니다." }
            }

            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startWriting()
            writer.startSession(atSourceTime: pts)
            writerSessionStarted = true
            recordingStartPTS = pts
        }

        guard let start = recordingStartPTS, CMSampleBufferGetPresentationTimeStamp(sampleBuffer) >= start else { return }
        pendingVideoSamples.append(sampleBuffer)
        if pendingVideoSamples.count > Self.maxPendingSamples {
            pendingVideoSamples.removeFirst(pendingVideoSamples.count - Self.maxPendingSamples)
        }
        pumpPendingVideo()
    }

    private func appendDelayedAudioIfRecording(_ sampleBuffer: CMSampleBuffer) {
        guard recordingActive, writerSessionStarted, let start = recordingStartPTS else { return }
        guard CMSampleBufferGetPresentationTimeStamp(sampleBuffer) >= start else { return }
        pendingAudioSamples.append(sampleBuffer)
        if pendingAudioSamples.count > Self.maxPendingSamples {
            pendingAudioSamples.removeFirst(pendingAudioSamples.count - Self.maxPendingSamples)
        }
        pumpPendingAudio()
    }

    private func pumpPendingVideo() {
        guard let videoInput = assetWriterVideoInput else { return }
        while videoInput.isReadyForMoreMediaData, !pendingVideoSamples.isEmpty {
            videoInput.append(pendingVideoSamples.removeFirst())
        }
    }

    private func pumpPendingAudio() {
        guard let audioInput = assetWriterAudioInput else { return }
        while audioInput.isReadyForMoreMediaData, !pendingAudioSamples.isEmpty {
            if audioInput.append(pendingAudioSamples.removeFirst()) {
                debugAudioAppended += 1
            } else {
                debugAudioDropped += 1
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

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoDataOutput {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            if compressionSession == nil {
                let width = Int32(CVPixelBufferGetWidth(pixelBuffer))
                let height = Int32(CVPixelBufferGetHeight(pixelBuffer))
                discoveredFrameWidth = width
                discoveredFrameHeight = height
                setupCompressionSession(width: width, height: height)
            }
            encodeForDelayBuffer(pixelBuffer: pixelBuffer, presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        } else {
            let hostTime = CACurrentMediaTime()
            audioDelayBufferLock.lock()
            audioDelayBuffer.append(BufferedAudioFrame(sampleBuffer: sampleBuffer, captureHostTime: hostTime))
            audioDelayBufferLock.unlock()
        }
    }

    private func encodeForDelayBuffer(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        guard let compressionSession else { return }
        let hostTime = CACurrentMediaTime()

        _ = VTCompressionSessionEncodeFrame(
            compressionSession,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: .invalid,
            frameProperties: nil,
            infoFlagsOut: nil
        ) { [weak self] status, _, encodedBuffer in
            guard let self, status == noErr,
                  let encodedBuffer, CMSampleBufferDataIsReady(encodedBuffer) else { return }
            self.videoDelayBufferLock.lock()
            self.videoDelayBuffer.append(BufferedVideoFrame(sampleBuffer: encodedBuffer, captureHostTime: hostTime))
            self.videoDelayBufferLock.unlock()
        }
    }
}
