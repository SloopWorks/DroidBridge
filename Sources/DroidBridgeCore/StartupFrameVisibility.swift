import CoreGraphics

/// Bounded thumbnail check for the solid-black video Android may emit before
/// an activity draws. Used only until the native host has shown visible video.
public enum StartupFrameVisibility {
    public static func hasVisibleContent(_ image: CGImage) -> Bool {
        var pixels=[UInt8](repeating:0,count:8*8*4)
        return pixels.withUnsafeMutableBytes { bytes in
            guard let context=CGContext(data:bytes.baseAddress,width:8,height:8,bitsPerComponent:8,bytesPerRow:32,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {return true}
            context.interpolationQuality = .low
            context.draw(image,in:CGRect(x:0,y:0,width:8,height:8))
            for index in stride(from:0,to:bytes.count,by:4) {
                if max(bytes[index],bytes[index+1],bytes[index+2]) >= 24 {return true}
            }
            return false
        }
    }
}
