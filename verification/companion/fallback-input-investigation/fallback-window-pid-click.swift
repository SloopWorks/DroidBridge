import AppKit
import CoreGraphics
import Foundation
// Diagnostic UI test: exact approved QA Player PID, current public window bounds,
// public HID cursor events only. No permissions requested or changed.
guard CommandLine.arguments.count == 4, let pid=Int32(CommandLine.arguments[1]), let x=Double(CommandLine.arguments[2]), let y=Double(CommandLine.arguments[3]), let app=NSRunningApplication(processIdentifier:pid), app.executableURL?.path == "/Users/patrick/Applications/DroidBridge Companion QA8.app/Contents/Resources/Runtime/Player.app/Contents/MacOS/scrcpy" else { exit(2) }
guard CGPreflightPostEventAccess() else { print("post_event_access_denied");exit(3) }
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],0) as? [[String:Any]] ?? []
let rows=windows.filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid && ($0[kCGWindowName as String] as? String) == "DroidBridge · Input Probe" }
guard rows.count == 1, let raw=rows[0][kCGWindowBounds as String] as? [String:Any], let box=CGRect(dictionaryRepresentation:raw as CFDictionary), x>=0,y>=32,x<box.width,y<box.height else { exit(4) }
let point=CGPoint(x:box.minX+x,y:box.minY+y)
let original=CGEvent(source:nil)?.location
app.activate(options:.activateAllWindows)
let stop=Date().addingTimeInterval(2)
while NSWorkspace.shared.frontmostApplication?.processIdentifier != pid && Date()<stop { RunLoop.current.run(until:Date().addingTimeInterval(0.02)) }
guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { print("activation_not_confirmed");exit(5) }
func send(_ type:CGEventType,at p:CGPoint) { let e=CGEvent(mouseEventSource:CGEventSource(stateID:.combinedSessionState),mouseType:type,mouseCursorPosition:p,mouseButton:.left)!; e.flags=[]; e.setIntegerValueField(.mouseEventWindowUnderMousePointer,value:Int64((rows[0][kCGWindowNumber as String] as! NSNumber).intValue)); e.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent,value:Int64((rows[0][kCGWindowNumber as String] as! NSNumber).intValue)); e.setIntegerValueField(.mouseEventClickState,value:1); if type == .mouseMoved { e.post(tap:.cghidEventTap) } else { e.postToPid(pid) } }
send(.mouseMoved,at:point); Thread.sleep(forTimeInterval:0.10)
send(.leftMouseDown,at:point); Thread.sleep(forTimeInterval:0.10)
send(.leftMouseUp,at:point); Thread.sleep(forTimeInterval:0.10)
let observed=CGEvent(source:nil)!.location
print(String(decoding:try! JSONSerialization.data(withJSONObject:["pid":pid,"window_id":rows[0][kCGWindowNumber as String]!,"requested_global_x":point.x,"requested_global_y":point.y,"observed_cursor_x":observed.x,"observed_cursor_y":observed.y,"frontmost_pid":NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1],options:[.sortedKeys]),as:UTF8.self))
if let old=original { send(.mouseMoved,at:old) }
