import AVFoundation
import CoreMedia
import VideoToolbox
import QuartzCore
import Photos
import Combine

final class CameraManager: NSObject, ObservableObject {

    static let delayPresets: [Double] = [3, 5, 8, 10, 15]

    @Published private(set) var delaySeconds: Double = CameraManager.delayPresets[1]
    @Published var isRecording = false
    @Published private(set) var recordingStartDate: Date?
    @Published var errorMessage: String?
    @Published private(set) var cameraPosition: AVCaptureDevice.Position = .back

    let displayLayer = AVSampleBufferDisplayLayer()

    private let session = AVCaptureSession()
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let audioDataOutput = AVCaptureAudioDataOutput()

    private let captureQueue = DispatchQueue(label: "camera.capture.queue")

    private static let targetWidth: Int32 = 1280
    private static let targetHeight: Int32 = 720
    private static let targetFPS: Double = 60

    private struct BufferedFrame {
        let sampleBuffer: CMSampleBuffer
        let captureHostTime: Double
    }

    private var videoDelayBuffer: [BufferedFrame] = []
    private let delayBufferLock = NSLock()
    private var displayLink: CADisplayLink?
    private var compressionSession: VTCompressionSession?

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
    }

    deinit {
        displayLink?.invalidate()
        if let compressionSession {
            VTCompressionSessionInvalidate(compressionSession)
        }
    }

    func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: cameraPosition),
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
        setupCompressionSession()
    }

    private func applyHighFrameRateFormat(to device: AVCaptureDevice) {
        let candidates = device.formats.filter { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return dims.width == Self.targetWidth && dims.height == Self.targetHeight
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
        if connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
        if connection.isVideoMirroringSupported {
            connection.isVideoMirrored = (cameraPosition == .front)
        }
    }

    private func setupCompressionSession() {
        var newSession: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Self.targetWidth,
            height: Self.targetHeight,
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
        VTSessionSetProperty(compressionSession, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(compressionSession, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(compressionSession, key: kVTCompressionPropertyKey_AverageBitRate, value: 5_000_000 as CFTypeRef)
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

    func switchCamera() {
        captureQueue.async { [weak self] in
            guard let self else { return }
            let newPosition: AVCaptureDevice.Position = self.cameraPosition == .back ? .front : .back

            guard let newDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: newPosition),
                  let newInput = try? AVCaptureDeviceInput(device: newDevice) else { return }

            self.session.beginConfiguration()
            defer { self.session.commitConfiguration() }

            guard let currentInput = self.session.inputs
                .compactMap({ $0 as? AVCaptureDeviceInput })
                .first(where: { $0.device.hasMediaType(.video) }) else { return }

            self.session.removeInput(currentInput)
            guard self.session.canAddInput(newInput) else {
                self.session.addInput(currentInput)
                return
            }
            self.session.addInput(newInput)
            self.applyHighFrameRateFormat(to: newDevice)
            self.configureVideoConnection()

            DispatchQueue.main.async { self.cameraPosition = newPosition }
        }
    }

    func stepDelay(forward: Bool) {
        guard let index = Self.delayPresets.firstIndex(of: delaySeconds) else {
            delaySeconds = forward ? Self.delayPresets.last! : Self.delayPresets.first!
            return
        }
        let newIndex = forward ? min(index + 1, Self.delayPresets.count - 1) : max(index - 1, 0)
        delaySeconds = Self.delayPresets[newIndex]
    }

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

        delayBufferLock.lock()
        var dueCount = 0
        for frame in videoDelayBuffer {
            guard now - frame.captureHostTime >= delay else { break }
            dueCount += 1
        }
        guard dueCount > 0 else {
            delayBufferLock.unlock()
            return
        }
        let dueFrames = Array(videoDelayBuffer[0..<dueCount])
        videoDelayBuffer.removeFirst(dueCount)
        delayBufferLock.unlock()

        for frame in dueFrames {
            guard displayLayer.isReadyForMoreMediaData else { break }
            markForImmediateDisplay(frame.sampleBuffer)
            displayLayer.enqueue(frame.sampleBuffer)
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
                AVVideoWidthKey: Self.targetWidth,
                AVVideoHeightKey: Self.targetHeight,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 8_000_000,
                    AVVideoExpectedSourceFrameRateKey: Int(Self.targetFPS)
                ]
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

            let writer = self.assetWriter
            self.assetWriterVideoInput?.markAsFinished()
            self.assetWriterAudioInput?.markAsFinished()

            writer?.finishWriting { [weak self] in
                guard let self else { return }
                DispatchQueue.main.async {
                    self.isRecording = false
                    self.recordingStartDate = nil
                }
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

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let isVideo = (output === videoDataOutput)

        if isVideo, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            encodeForDelayBuffer(pixelBuffer: pixelBuffer, presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        }

        recordingQueue.async { [weak self] in
            self?.appendToWriterIfRecording(sampleBuffer: sampleBuffer, isVideo: isVideo)
        }
    }

    private func encodeForDelayBuffer(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        guard let compressionSession else { return }
        let hostTime = CACurrentMediaTime()

        VTCompressionSessionEncodeFrameWithOutputHandler(
            compressionSession,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: .invalid,
            frameProperties: nil,
            infoFlagsOut: nil
        ) { [weak self] status, _, encodedBuffer in
            guard let self, status == noErr,
                  let encodedBuffer, CMSampleBufferDataIsReady(encodedBuffer) else { return }
            self.delayBufferLock.lock()
            self.videoDelayBuffer.append(BufferedFrame(sampleBuffer: encodedBuffer, captureHostTime: hostTime))
            self.delayBufferLock.unlock()
        }
    }

    private func appendToWriterIfRecording(sampleBuffer: CMSampleBuffer, isVideo: Bool) {
        guard recordingActive, let writer = assetWriter else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if !writerSessionStarted {
            guard isVideo else { return }
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
