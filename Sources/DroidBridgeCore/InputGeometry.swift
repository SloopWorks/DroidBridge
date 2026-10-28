import CoreGraphics
import Foundation

public enum InputGeometry {
    public static func aspectFitRect(videoWidth: Int, videoHeight: Int, bounds: CGRect) -> CGRect {
        guard videoWidth > 0, videoHeight > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / CGFloat(videoWidth), bounds.height / CGFloat(videoHeight))
        let size = CGSize(width: CGFloat(videoWidth) * scale, height: CGFloat(videoHeight) * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }
    public static func coordinates(point: CGPoint, rect: CGRect, videoWidth: Int, videoHeight: Int, clamp: Bool = false) -> (x: Int, y: Int)? {
        guard rect.width > 0, rect.height > 0, videoWidth > 0, videoHeight > 0, clamp || rect.contains(point) else { return nil }
        return (max(0, min(videoWidth - 1, Int((point.x - rect.minX) / rect.width * CGFloat(videoWidth)))), max(0, min(videoHeight - 1, Int((point.y - rect.minY) / rect.height * CGFloat(videoHeight)))))
    }
}
