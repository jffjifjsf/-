import CoreImage
import Foundation

/// 滤镜预设。
///
/// 全部基于 Core Image 内置滤镜（`CIPhotoEffect*` + `CIColorControls`），
/// 不依赖外部 LUT 文件，所以包体不增加，也不会踩 LUT 解密那类坑。
/// 想换成真正的 .cube LUT，只需在这里改成 `CIColorCube` 并加载对应数据。
enum FilterPreset: String, CaseIterable, Identifiable {
    case none
    case film
    case instant
    case mono
    case fade

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "原图"
        case .film: return "胶片"
        case .instant: return "拍立得"
        case .mono: return "黑白"
        case .fade: return "褪色"
        }
    }

    /// 把滤镜应用到一张 CIImage 上。
    func apply(to image: CIImage) -> CIImage {
        switch self {
        case .none:
            return image
        case .film:
            return Self.chain(image, effect: "CIPhotoEffectTransfer", contrast: 1.06, saturation: 1.04)
        case .instant:
            return Self.chain(image, effect: "CIPhotoEffectInstant", contrast: 1.02, saturation: 1.02)
        case .mono:
            return Self.chain(image, effect: "CIPhotoEffectMono", contrast: 1.10, saturation: 0.0)
        case .fade:
            return Self.chain(image, effect: "CIPhotoEffectFade", contrast: 0.96, saturation: 0.92)
        }
    }

    private static func chain(
        _ image: CIImage,
        effect: String,
        contrast: CGFloat,
        saturation: CGFloat
    ) -> CIImage {
        var output = image

        if let filter = CIFilter(name: effect) {
            filter.setValue(output, forKey: kCIInputImageKey)
            if let result = filter.outputImage {
                output = result
            }
        }

        if let controls = CIFilter(name: "CIColorControls") {
            controls.setValue(output, forKey: kCIInputImageKey)
            controls.setValue(contrast, forKey: kCIInputContrastKey)
            controls.setValue(saturation, forKey: kCIInputSaturationKey)
            if let result = controls.outputImage {
                output = result
            }
        }

        return output
    }
}
