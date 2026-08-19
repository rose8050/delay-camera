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
///        └─ audio ──> 원본 그대로 ──> 지연 링버퍼 ──(같은 N초 기준 drain)──> AVAssetWriter audio (녹화 중일 때만)
final class CameraManager: NSObject, ObservableObject {

    // MARK: Published UI state

    static let delayPresets: [Double] = [15, 20, 30, 40]

    /// 앱 실행 시 기본 지연 시간은 30초.
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

    // MARK: Recording

    private let recordingQueue = DispatchQueue(label: "camera.recording.queue")
    private var assetWriter: AVAssetWriter?
    private var assetWriterVideoInput: AVAssetWriterInput?
    private var assetWriterAudioInput: AVAssetWriterInput?
    private var recordingStartPTS: CMTime?
    private var writerSessionStarted = false
    private var recordingActive = false

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
        applyHighFrameRateFormat(to: camera)
        session.sessionPreset = .inputPriority

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
        configureVideoConnection()

        audioDataOutput.setSampleBufferDelegate(self, queue: captureQueue)
        if session.canAddOutput(audioDataOutput) {
            session.addOutput(audioDataOutput)
        }

        session.commitConfiguration()
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

    func setDelay(_ seconds: Double) {
        guard Self.delayPresets.contains(seconds) else { return }
        delaySeconds = seconds
    }

    // MARK: - Delay buffer drain

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
                AVSampleRateKey: 44100,
                AVEncoderBitRateKey: 64000
            ]
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioInput.expectsMediaDataInRealTime = true

            self.assetWriter = writer
            self.assetWriterVideoInput = nil
            self.assetWriterAudioInput = audioInput
            self.writerSessionStarted = false
            self.recordingStartPTS = nil
            self.recordingActive = true

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
                DispatchQueue.main.async {
                    self.isRecording = false
                    self.recordingStartDate = nil
                    self.errorMessage = "녹화 시간이 너무 짧아 저장할 프레임이 없습니다."
                }
                return
            }

            self.assetWriterVideoInput?.markAsFinished()
            self.assetWriterAudioInput?.markAsFinished()

            writer.finishWriting { [weak self] in
                guard let self else { return }
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
            guard writer.canAdd(videoInput) else { return }
            writer.add(videoInput)
            if let audioInput = assetWriterAudioInput, writer.canAdd(audioInput) {
                writer.add(audioInput)
            }
            assetWriterVideoInput = videoInput

            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startWriting()
            writer.startSession(atSourceTime: pts)
            writerSessionStarted = true
            recordingStartPTS = pts
        }

        guard let start = recordingStartPTS, CMSampleBufferGetPresentationTimeStamp(sampleBuffer) >= start else { return }
        if assetWriterVideoInput?.isReadyForMoreMediaData == true {
            assetWriterVideoInput?.append(sampleBuffer)
        }
    }

    private func appendDelayedAudioIfRecording(_ sampleBuffer: CMSampleBuffer) {
        guard recordingActive, writerSessionStarted, let start = recordingStartPTS else { return }
        guard CMSampleBufferGetPresentationTimeStamp(sampleBuffer) >= start else { return }
        if assetWriterAudioInput?.isReadyForMoreMediaData == true {
            assetWriterAudioInput?.append(sampleBuffer)
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

// MARK: - Capture Delegate

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
