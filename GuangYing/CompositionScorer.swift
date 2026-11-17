import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Vision

/// 单次评估得到的构图分数与建议。
struct CompositionScore: Equatable {
    var total: Int = 0
    /// 各维度均为 0...1
    var placement: Double = 0
    var level: Double = 0
    var exposure: Double = 0
    var subjectSize: Double = 0

    var hints: [String] = []
    var hasSubject: Bool = false
    var horizonAngle: Double = 0

    static let empty = CompositionScore()

    static func == (lhs: CompositionScore, rhs: CompositionScore) -> Bool {
        lhs.total == rhs.total && lhs.hints == rhs.hints
    }
}

/// 基于系统 Vision 框架的构图评分器。
///
/// 不依赖任何第三方模型：主体检测用注意力显著性 + 人脸，水平用地平线检测，
/// 曝光用 Y 平面直方图，主体占比用边界框面积。全部在端侧离线完成。
final class CompositionScorer {

    private let faceRequest = VNDetectFaceRectanglesRequest()
    private let saliencyRequest = VNGenerateAttentionBasedSaliencyImageRequest()
    private let horizonRequest = VNDetectHorizonRequest()

    private var smoothedTotal: Double?

    /// 三分点，用于衡量主体位置
    private let thirds: [CGPoint] = [
        CGPoint(x: 1.0 / 3.0, y: 1.0 / 3.0),
        CGPoint(x: 2.0 / 3.0, y: 1.0 / 3.0),
        CGPoint(x: 1.0 / 3.0, y: 2.0 / 3.0),
        CGPoint(x: 2.0 / 3.0, y: 2.0 / 3.0)
    ]

    func reset() {
        smoothedTotal = nil
    }

    /// - Parameters:
    ///   - pixelBuffer: 相机会话输出的 YUV 双平面缓冲区
    ///   - orientation: 依据前后摄像头与设备方向给出的图像方向
    func evaluate(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> CompositionScore {
        var result = CompositionScore()

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        try? handler.perform([faceRequest, saliencyRequest, horizonRequest])

        // 1. 主体：优先人脸，其次注意力显著性区域
        var subject: CGRect?
        var faceCount = 0
        if let faces = faceRequest.results, !faces.isEmpty {
            faceCount = faces.count
            subject = faces.max { lhs, rhs in
                (lhs.boundingBox.width * lhs.boundingBox.height) < (rhs.boundingBox.width * rhs.boundingBox.height)
            }?.boundingBox
        }

        if subject == nil,
           let salient = saliencyRequest.results?.first,
           let objects = salient.salientObjects, !objects.isEmpty {
            subject = objects.max { lhs, rhs in
                (lhs.boundingBox.width * lhs.boundingBox.height) < (rhs.boundingBox.width * rhs.boundingBox.height)
            }?.boundingBox
        }

        if let box = subject {
            result.hasSubject = true
            result.placement = placementScore(for: box, faceCount: faceCount)
            result.subjectSize = sizeScore(for: box)
        } else {
            // 没有主体时不给奖励也不重罚：按居中构图处理，提示用户
            result.placement = 0.45
            result.subjectSize = 0.45
        }

        // 2. 水平
        var angleDegrees = 0.0
        if let horizon = horizonRequest.results?.first {
            angleDegrees = Double(horizon.angle) * 180.0 / .pi
            if faceCount == 0 {
                result.level = max(0, 1 - min(1, abs(angleDegrees) / 12.0))
            } else {
                // 有人像时地平线常常不可靠，降低权重影响
                result.level = max(0.6, max(0, 1 - min(1, abs(angleDegrees) / 20.0)))
            }
        } else {
            result.level = 1.0
        }
        result.horizonAngle = angleDegrees

        // 3. 曝光
        let luma = Self.lumaStats(pixelBuffer: pixelBuffer)
        result.exposure = Self.exposureScore(luma)

        // 4. 汇总
        var weighted = result.placement * 0.36
            + result.level * 0.20
            + result.exposure * 0.26
            + result.subjectSize * 0.18
        // 完全没有主体时封顶，避免"空画面"拿高分
        if !result.hasSubject {
            weighted = min(weighted, 0.62)
        }

        let raw = max(0, min(1, weighted)) * 100
        // 指数移动平均，避免数字剧烈跳动
        let smoothed = smoothedTotal.map { $0 * 0.72 + raw * 0.28 } ?? raw
        smoothedTotal = smoothed

        result.total = Int(smoothed.rounded())
        result.hints = Self.hints(for: result, subject: subject, luma: luma)
        return result
    }

    // MARK: - 单张照片评分（连拍取最优用）

    /// 对一张已拍摄的照片评分，仅用于**同一组连拍之间排序**。
    ///
    /// 连拍间隔只有几十毫秒，曝光与光线几乎不变，所以这里不做曝光项计算
    /// （固定为 1.0）。排名比较的是构图三项，结果与带曝光的排序一致。
    /// 由于是单次比较，不使用指数平滑。
    func evaluate(cgImage: CGImage, orientation: CGImagePropertyOrientation) -> CompositionScore {
        var result = CompositionScore()

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        try? handler.perform([faceRequest, saliencyRequest, horizonRequest])

        var subject: CGRect?
        var faceCount = 0
        if let faces = faceRequest.results, !faces.isEmpty {
            faceCount = faces.count
            subject = faces.max { lhs, rhs in
                (lhs.boundingBox.width * lhs.boundingBox.height) < (rhs.boundingBox.width * rhs.boundingBox.height)
            }?.boundingBox
        }
        if subject == nil,
           let salient = saliencyRequest.results?.first,
           let objects = salient.salientObjects, !objects.isEmpty {
            subject = objects.max { lhs, rhs in
                (lhs.boundingBox.width * lhs.boundingBox.height) < (rhs.boundingBox.width * rhs.boundingBox.height)
            }?.boundingBox
        }

        if let box = subject {
            result.hasSubject = true
            result.placement = placementScore(for: box, faceCount: faceCount)
            result.subjectSize = sizeScore(for: box)
        } else {
            result.placement = 0.45
            result.subjectSize = 0.45
        }

        var angleDegrees = 0.0
        if let horizon = horizonRequest.results?.first {
            angleDegrees = Double(horizon.angle) * 180.0 / .pi
            result.level = max(0, 1 - min(1, abs(angleDegrees) / 12.0))
        } else {
            result.level = 1.0
        }
        result.horizonAngle = angleDegrees

        // 连拍之间曝光不变，固定中性值，只比较构图
        result.exposure = 1.0

        var weighted = result.placement * 0.36
            + result.level * 0.20
            + result.exposure * 0.26
            + result.subjectSize * 0.18
        if !result.hasSubject {
            weighted = min(weighted, 0.62)
        }
        result.total = Int((max(0, min(1, weighted)) * 100).rounded())
        return result
    }

    // MARK: - 维度计算

    private func placementScore(for box: CGRect, faceCount: Int) -> Double {
        let center = CGPoint(x: box.midX, y: box.midY)
        let nearest = thirds.map { p -> CGFloat in
            let dx = p.x - center.x
            let dy = p.y - center.y
            return sqrt(dx * dx + dy * dy)
        }.min() ?? 0.5

        // 距离 0 得满分，超过 0.32 得 0 分
        let score = max(0, 1 - Double(nearest) / 0.32)

        // 人脸靠近中线对称构图也是常见的合格构图
        if faceCount > 0 {
            let horizontalOffset = abs(box.midX - 0.5)
            if horizontalOffset < 0.06 {
                return max(score, 0.82)
            }
        }
        return score
    }

    private func sizeScore(for box: CGRect) -> Double {
        let area = Double(box.width * box.height)
        switch area {
        case ..<0.04:
            return 0.25
        case 0.04..<0.12:
            return 0.25 + (area - 0.04) / 0.08 * 0.55
        case 0.12...0.45:
            return 1.0
        case 0.45...0.70:
            return 1.0 - (area - 0.45) / 0.25 * 0.45
        default:
            return 0.55
        }
    }

    // MARK: - 像素统计

    private struct LumaStats {
        var mean: Double
        var darkClipped: Double
        var brightClipped: Double
    }

    private static func lumaStats(pixelBuffer: CVPixelBuffer) -> LumaStats {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard CVPixelBufferGetPlaneCount(pixelBuffer) > 0,
              let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
            return LumaStats(mean: 0.45, darkClipped: 0, brightClipped: 0)
        }

        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        guard width > 0, height > 0 else {
            return LumaStats(mean: 0.45, darkClipped: 0, brightClipped: 0)
        }

        let pointer = base.assumingMemoryBound(to: UInt8.self)
        let stepX = max(1, width / 64)
        let stepY = max(1, height / 64)

        var sum = 0.0
        var count = 0.0
        var dark = 0.0
        var bright = 0.0

        var y = 0
        while y < height {
            let row = pointer.advanced(by: y * bytesPerRow)
            var x = 0
            while x < width {
                let v = Double(row[x]) / 255.0
                sum += v
                count += 1
                if v < 0.04 { dark += 1 }
                if v > 0.96 { bright += 1 }
                x += stepX
            }
            y += stepY
        }

        guard count > 0 else {
            return LumaStats(mean: 0.45, darkClipped: 0, brightClipped: 0)
        }
        return LumaStats(mean: sum / count, darkClipped: dark / count, brightClipped: bright / count)
    }

    private static func exposureScore(_ stats: LumaStats) -> Double {
        let meanPenalty = min(1.0, abs(stats.mean - 0.45) / 0.45)
        let clipPenalty = min(1.0, (stats.darkClipped + stats.brightClipped) * 3.0)
        return max(0, 1.0 - 0.6 * meanPenalty - 0.4 * clipPenalty)
    }

    // MARK: - 建议文案

    private static func hints(for score: CompositionScore, subject: CGRect?, luma: LumaStats) -> [String] {
        var hints: [String] = []

        if !score.hasSubject {
            hints.append("没找到明确主体，靠近一点或让画面更简洁")
        } else if let box = subject {
            if score.placement < 0.55 {
                if box.midX < 0.42 {
                    hints.append("主体偏左，往右挪一点")
                } else if box.midX > 0.58 {
                    hints.append("主体偏右，往左挪一点")
                } else {
                    hints.append("主体可放在三分点附近")
                }
            }
            if score.subjectSize < 0.45 {
                if Double(box.width * box.height) < 0.12 {
                    hints.append("主体太小，靠近或变焦")
                } else {
                    hints.append("主体太满，后退一点")
                }
            }
        }

        if score.horizonAngle != 0, score.level < 0.72 {
            let deg = Int(score.horizonAngle.rounded())
            hints.append("地平线倾斜约 \(abs(deg))°，端平手机")
        }

        if score.exposure < 0.55 {
            if luma.mean < 0.3 {
                hints.append("画面偏暗，找点光或提高曝光")
            } else if luma.mean > 0.65 {
                hints.append("画面偏亮，避开强光或降低曝光")
            } else {
                hints.append("明暗反差过大，留意高光与阴影")
            }
        }

        if hints.isEmpty {
            hints.append(score.total >= 82 ? "构图不错，可以按下快门" : "画面均衡，还可以再等等")
        }
        return Array(hints.prefix(2))
    }
}
