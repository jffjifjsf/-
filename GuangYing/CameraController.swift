import AVFoundation
import Combine
import CoreImage
import Foundation
import ImageIO
import Photos
import QuartzCore
import UIKit

/// 相机会话管理：预览采集、节流评分、拍照与写入相册。
///
/// 刻意不使用 Swift Concurrency 的严格隔离模型，全部走串行队列 + 主线程回写，
/// 这样在 Swift 5 语言模式下行为最稳定，也不受 Swift 6 隔离规则影响。
final class CameraController: NSObject, ObservableObject {

    // MARK: - 对外状态

    @Published private(set) var score = CompositionScore()
    @Published private(set) var permissionDenied = false
    @Published private(set) var isFrontCamera = false
    @Published private(set) var isCapturing = false
    @Published var autoCaptureEnabled = false {
        didSet {
            if !autoCaptureEnabled { recentScores.removeAll() }
        }
    }
    @Published var toast: String?

    /// 当前滤镜。为 `.none` 时走系统原生预览层（流畅），否则走 Core Image 渲染管道。
    @Published var filter: FilterPreset = .none

    /// 已渲染的滤镜帧。预览层直接订阅，避开 SwiftUI 状态刷新。
    let frameSubject = PassthroughSubject<UIImage, Never>()

    /// 自动快门阈值
    var autoCaptureThreshold = 85
    /// 连续多少帧达标才认为「构图稳定」
    private let stableFrames = 4
    /// 滚动窗口长度，用于在窗口内挑最高分那一帧
    private let scoreWindow = 8

    let session = AVCaptureSession()

    // MARK: - 内部

    private let sessionQueue = DispatchQueue(label: "guangying.session")
    private let videoQueue = DispatchQueue(label: "guangying.video")
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let scorer = CompositionScorer()

    private var videoInput: AVCaptureDeviceInput?
    private var isConfigured = false
    private var lastAnalysisTime: CFTimeInterval = 0
    private var lastCaptureTime: CFTimeInterval = 0

    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var lastFilterRender: CFTimeInterval = 0
    /// 滤镜预览帧率。12fps 足够看清色调，又不至于让 GPU 持续满载。
    private let filterInterval: CFTimeInterval = 1.0 / 12.0
    /// 预览渲染的最大边长，控制单帧渲染成本
    private let previewMaxDimension: CGFloat = 900
    /// 最近若干帧的分数，用于「稳定判定 + 窗口取最优」
    private var recentScores: [Int] = []
    /// 连拍缓存：(唯一 ID, JPEG 数据)
    private var burstPhotos: [(id: Int64, data: Data)] = []
    /// 一次连拍要收几张
    private let burstCount = 3
    /// 本次连拍是否已结算，防止超时与回调重复处理
    private var burstResolved = false

    /// 分析节流间隔（秒）。每帧都推理会明显发热掉帧。
    private let analysisInterval: CFTimeInterval = 0.22

    // MARK: - 生命周期

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.configureAndRun()
                } else {
                    DispatchQueue.main.async { self.permissionDenied = true }
                }
            }
        default:
            permissionDenied = true
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    private func configureAndRun() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.isConfigured {
                self.configureSession()
                self.isConfigured = true
            }
            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .high

        if let device = Self.device(for: .back),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
            videoInput = input
        }

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }

        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }

        applyPortraitOrientation()
        session.commitConfiguration()
    }

    private static func device(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .builtInDualCamera,
            .builtInTripleCamera
        ]
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: position
        ).devices.first
    }

    /// 竖屏预览。iOS 17 起了新 API，这里兼顾两版。
    private func applyPortraitOrientation() {
        for connection in [videoOutput.connection(with: .video), photoOutput.connection(with: .video)] {
            guard let connection, connection.isVideoOrientationSupported else { continue }
            connection.videoOrientation = .portrait
        }
    }

    // MARK: - 前后摄像头切换

    func flipCamera() {
        sessionQueue.async { [weak self] in
            guard let self, let current = self.videoInput else { return }
            let target: AVCaptureDevice.Position = current.device.position == .back ? .front : .back
            guard let device = Self.device(for: target),
                  let newInput = try? AVCaptureDeviceInput(device: device) else { return }

            self.session.beginConfiguration()
            self.session.removeInput(current)
            if self.session.canAddInput(newInput) {
                self.session.addInput(newInput)
                self.videoInput = newInput
                self.applyPortraitOrientation()
                DispatchQueue.main.async {
                    self.isFrontCamera = (target == .front)
                    self.scorer.reset()
                }
            } else {
                self.session.addInput(current)
            }
            self.session.commitConfiguration()
        }
    }

    // MARK: - 拍照

    /// 连拍取最优：一次拍 3 张，逐张评分，只保存最高分那一张。
    ///
    /// 单张快门受手抖影响很大；连拍三张再挑，命中「构图最好的那一瞬间」的概率
    /// 明显更高，而用户只感知为「按了一次快门」。
    func capturePhoto() {
        let now = CACurrentMediaTime()
        guard now - lastCaptureTime > 0.9 else { return }
        lastCaptureTime = now

        burstPhotos.removeAll()
        burstResolved = false
        isCapturing = true

        sessionQueue.async { [weak self] in
            guard let self else { return }
            for _ in 0..<self.burstCount {
                let settings = AVCapturePhotoSettings()
                self.photoOutput.capturePhoto(with: settings, delegate: self)
            }
        }

        // 兜底：有的帧可能回调失败，不能一直卡在 isCapturing
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.isCapturing, !self.burstResolved else { return }
            self.finishBurst()
        }
    }

    /// 从连拍缓存里挑出构图分数最高的一张存盘。
    private func finishBurst() {
        guard !burstResolved else { return }
        burstResolved = true

        let photos = burstPhotos
        burstPhotos.removeAll()

        guard !photos.isEmpty else {
            isCapturing = false
            toast = "拍照失败，请重试"
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            // 独立实例：VNRequest 不保证并发安全，不能和实时评分共用
            let scorer = CompositionScorer()
            var bestScore = -1
            var bestData: Data?

            for item in photos {
                guard let image = UIImage(data: item.data),
                      let cgImage = image.cgImage else { continue }
                let score = scorer.evaluate(cgImage: cgImage, orientation: .up).total
                if score > bestScore {
                    bestScore = score
                    bestData = item.data
                }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard let data = bestData else {
                    self.isCapturing = false
                    self.toast = "拍照失败，请重试"
                    return
                }
                let note = photos.count > 1 ? "已保存最优帧 · \(bestScore) 分" : nil
                self.savePhotoData(data, note: note)
            }
        }
    }

    private func savePhotoData(_ data: Data, note: String? = nil) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    self?.toast = "未获得相册写入权限，请到设置里开启"
                    self?.isCapturing = false
                }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            } completionHandler: { success, _ in
                DispatchQueue.main.async {
                    if success {
                        self?.toast = note ?? "已保存到相册"
                    } else {
                        self?.toast = "保存失败，请重试"
                    }
                    self?.isCapturing = false
                }
            }
        }
    }
}

// MARK: - 视频帧

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        guard now - lastAnalysisTime >= analysisInterval else { return }
        lastAnalysisTime = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let orientation: CGImagePropertyOrientation = isFrontCamera ? .leftMirrored : .right
        let result = scorer.evaluate(pixelBuffer: pixelBuffer, orientation: orientation)

        // 滤镜预览：有滤镜时才渲染，且降到 12fps，避免持续占满 GPU
        if filter != .none {
            let tick = CACurrentMediaTime()
            if tick - lastFilterRender >= filterInterval {
                lastFilterRender = tick
                renderFilteredFrame(pixelBuffer: pixelBuffer, orientation: orientation)
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.score = result
            self.handleAutoCaptureIfNeeded(score: result.total)
        }
    }

    /// 把当前帧套上滤镜并渲染成 UIImage 推给预览层。
    ///
    /// 在 videoQueue 上执行；缩放后再渲染，单帧成本可控。
    private func renderFilteredFrame(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) {
        let source = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
        let filtered = filter.apply(to: source)

        let extent = filtered.extent
        guard extent.width > 1, extent.height > 1 else { return }

        let scale = min(1.0, previewMaxDimension / max(extent.width, extent.height))
        let scaled = filtered.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let cgImage = ciContext.createCGImage(scaled, from: scaled.extent) else { return }
        frameSubject.send(UIImage(cgImage: cgImage))
    }

    /// 自动构图快门：连续若干帧达标，且当前帧是滚动窗口内的最优帧时才拍。
    ///
    /// 只看「达标」会在手抖抖动时误拍；取窗口最优能让快门落在构图最好的那一刻，
    /// 而不是刚跨过阈值的那一帧。
    private func handleAutoCaptureIfNeeded(score: Int) {
        recentScores.append(score)
        if recentScores.count > scoreWindow {
            recentScores.removeFirst()
        }

        guard autoCaptureEnabled, !isCapturing else { return }
        guard recentScores.count >= stableFrames else { return }

        let tail = recentScores.suffix(stableFrames)
        guard tail.allSatisfy({ $0 >= autoCaptureThreshold }) else { return }

        // 必须是窗口内最高分：等构图「到顶」再按，而不是刚够线就按
        guard let peak = recentScores.max(), score >= peak else { return }

        recentScores.removeAll()
        capturePhoto()
    }
}

// MARK: - 拍照回调

extension CameraController: AVCapturePhotoCaptureDelegate {

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else {
            // 单帧失败不致命：其余帧仍可能成功，交给超时兜底结算
            return
        }
        let id = photo.resolvedSettings.uniqueID
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.burstResolved else { return }
            self.burstPhotos.append((id, data))
            if self.burstPhotos.count >= self.burstCount {
                self.finishBurst()
            }
        }
    }
}
