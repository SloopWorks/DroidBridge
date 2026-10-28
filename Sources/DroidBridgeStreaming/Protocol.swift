import Foundation
import CoreGraphics

public enum AndroidInputEvent {
    case touch(action: UInt8, x: Int, y: Int, width: Int, height: Int)
    case scroll(x: Int, y: Int, width: Int, height: Int, horizontal: Double, vertical: Double)
    case key(action: UInt8, keycode: UInt32, metastate: UInt32)
    case text(String)
    case clipboard(String, paste: Bool)
    case back
}
public struct SessionMetrics {
    public var frames: Int = 0
    public var bytes: Int = 0
    public var width: Int = 0
    public var height: Int = 0
    public init() {}
}

extension Data {
    mutating func be<T: FixedWidthInteger>(_ value: T) { var v = value.bigEndian; Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) } }
    func number(_ offset: Int, _ count: Int) -> UInt64 { self[offset..<(offset+count)].reduce(0) { ($0 << 8) | UInt64($1) } }
}
/// scrcpy v5.0.1 control wire format. Numeric dimensions always describe the
/// last received frame, including letterboxing already removed by the view.
public enum ScrcpyControl {
    static func position(_ data: inout Data, _ x: Int, _ y: Int, _ w: Int, _ h: Int) {
        data.be(UInt32(clamping: max(0, min(x, w-1)))); data.be(UInt32(clamping: max(0, min(y, h-1))))
        data.be(UInt16(clamping: w)); data.be(UInt16(clamping: h))
    }
    public static func encode(_ event: AndroidInputEvent) -> Data {
        var d = Data()
        switch event {
        case let .touch(action,x,y,w,h):
            d.append(contentsOf: [2,action]); d.be(UInt64.max-1); position(&d,x,y,w,h)
            d.be(UInt16(action == 1 ? 0 : 65535)); d.be(UInt32(0)); d.be(UInt32(0))
        case let .scroll(x,y,w,h,horizontal,vertical):
            d.append(3); position(&d,x,y,w,h)
            d.be(Int16(max(-32768,min(32767,horizontal / 16 * 32768))))
            d.be(Int16(max(-32768,min(32767,vertical / 16 * 32768)))); d.be(UInt32(0))
        case let .key(action,code,meta): d.append(contentsOf: [0,action]); d.be(code); d.be(UInt32(0)); d.be(meta)
        case let .text(text):
            d.append(1); let bytes = utf8Prefix(text, maxBytes: 300); d.be(UInt32(bytes.count)); d.append(bytes)
        case let .clipboard(text,paste):
            d.append(9); d.be(UInt64(0)); d.append(paste ? 1 : 0)
            let bytes = utf8Prefix(text, maxBytes: 262130); d.be(UInt32(bytes.count)); d.append(bytes)
        case .back: d.append(contentsOf: [4,0,4,1])
        }
        return d
    }
    public static func resize(width: Int, height: Int) -> Data {
        var d = Data([21]); d.be(UInt16(clamping: max(160,min(4096,width)) / 8 * 8)); d.be(UInt16(clamping: max(160,min(4096,height)) / 8 * 8)); return d
    }
    static func startApp(_ package: String) -> Data { let bytes = Data(package.utf8); var d = Data([16,UInt8(bytes.count)]); d.append(bytes); return d }
    static func utf8Prefix(_ text: String, maxBytes: Int) -> Data {
        var result = Data()
        for character in text { let bytes = Array(String(character).utf8); if result.count + bytes.count > maxBytes { break }; result.append(contentsOf: bytes) }
        return result
    }
}
