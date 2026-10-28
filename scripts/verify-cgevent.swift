import AppKit
import CoreGraphics
import Foundation
// Public, process-targeted OS events; target must be an explicitly owned Player PID.
guard CommandLine.arguments.count == 3, let pid = Int32(CommandLine.arguments[1]) else { fputs("usage: verify-cgevent PLAYER_PID WORD\n",stderr); exit(64) }
let word = CommandLine.arguments[2]
let rows = CGWindowListCopyWindowInfo(.optionAll,kCGNullWindowID) as? [[String:Any]] ?? []
guard let row = rows.first(where:{ ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }), let bounds = row[kCGWindowBounds as String] as? [String:Any], let rect = CGRect(dictionaryRepresentation:bounds as CFDictionary) else { fputs("No owned window metadata\n",stderr); exit(1) }
print("Targeted OS input pid=\(pid) bounds=\(rect) AXtrusted=\(AXIsProcessTrusted())")
NSRunningApplication(processIdentifier:pid)?.activate(options:[])
let content = CGRect(x:rect.minX,y:rect.minY+28,width:rect.width,height:rect.height-28)
func click(_ normalizedY:CGFloat) {
    let point = CGPoint(x:content.midX,y:content.minY+content.height*normalizedY)
    for type:CGEventType in [.leftMouseDown,.leftMouseUp] {
        CGEvent(mouseEventSource:nil,mouseType:type,mouseCursorPosition:point,mouseButton:.left)?.postToPid(pid)
        Thread.sleep(forTimeInterval:0.1)
    }
}
click(225.0/1080.0);click(295.0/1080.0)
Thread.sleep(forTimeInterval:0.2)
let units=Array(word.utf16)
for down in [true,false] {
    let event=CGEvent(keyboardEventSource:nil,virtualKey:0,keyDown:down)!
    units.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength:$0.count,unicodeString:$0.baseAddress!) }
    event.postToPid(pid)
}
print("Posted OS events; Android receipt is required separately. Posting success is not input acceptance.")
