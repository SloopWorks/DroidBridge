#import <AppKit/AppKit.h>
#include <stdlib.h>
static double started;
static NSString *root;
static NSView *videoView(void) {
 for(NSWindow *w in NSApp.windows) if([NSStringFromClass(w.contentView.class) containsString:@"AndroidVideoView"]) return w.contentView;
 return nil;
}
static void capture(NSView *v,NSString *name) {
 [v displayIfNeeded];NSBitmapImageRep *b=[v bitmapImageRepForCachingDisplayInRect:v.bounds];
 if(b){[v cacheDisplayInRect:v.bounds toBitmapImageRep:b];[[b representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[root stringByAppendingPathComponent:name] atomically:YES];}
}
static void receipt(NSDictionary *data) {
 [[NSJSONSerialization dataWithJSONObject:data options:NSJSONWritingPrettyPrinted error:NULL] writeToFile:[root stringByAppendingPathComponent:@"ui.json"] atomically:YES];
}
__attribute__((constructor)) static void begin(void) {
 unsetenv("DYLD_INSERT_LIBRARIES");started=NSProcessInfo.processInfo.systemUptime;root=NSProcessInfo.processInfo.environment[@"DROIDBRIDGE_LAUNCH_UX_OUT"];
 dispatch_async(dispatch_get_main_queue(),^{
 __block BOOL seen=NO,live=NO,launcherFlash=NO;__block NSInteger number=-1;__block double visibleAt=0,liveAt=0;
 __block NSView *observed=nil;
 __block NSMutableDictionary *data=[NSMutableDictionary dictionary];
 NSTimer *timer=[NSTimer timerWithTimeInterval:.02 repeats:YES block:^(NSTimer *t){
  double now=NSProcessInfo.processInfo.systemUptime-started;
  for(NSWindow *w in NSApp.windows)if([w.title isEqual:@"DroidBridge"] && w.visible)launcherFlash=YES;
  NSView *v=videoView()?:observed;
  if(v.window.visible && !seen){seen=YES;observed=v;number=v.window.windowNumber;visibleAt=now;capture(v,@"loading.png");
   data[@"first_window_seconds"]=@(now);data[@"first_window_number"]=@(number);data[@"loading_accessibility"]=v.accessibilityLabel?:@"";data[@"initial_content_width"]=@(v.bounds.size.width);data[@"initial_content_height"]=@(v.bounds.size.height);receipt(data);
  }
  if(seen && !live && [v.accessibilityLabel isEqual:@"Launch UX Probe"]){
   live=YES;liveAt=now;capture(v,@"live.png");data[@"live_seconds"]=@(now);data[@"live_window_number"]=@(v.window.windowNumber);
   if([NSProcessInfo.processInfo.environment[@"DROIDBRIDGE_LAUNCH_UX_RESIZE"] isEqual:@"1"])[v.window setContentSize:NSMakeSize(420,560)];
  }
  BOOL fallback=[NSProcessInfo.processInfo.environment[@"DROIDBRIDGE_LAUNCH_UX_BACKEND"] isEqual:@"scrcpy"];
  if((live && now-liveAt>1.4) || (fallback && seen && NSApp.activationPolicy==NSApplicationActivationPolicyAccessory && now-visibleAt>4)){
   if(live)capture(v,@"live-stable.png");data[@"passed"]=@YES;data[@"launcher_visible_during_launch"]=@(launcherFlash);data[@"fallback_handoff"]=@(fallback);data[@"final_content_width"]=@(v.bounds.size.width);data[@"final_content_height"]=@(v.bounds.size.height);data[@"physical_focus_verified"]=@NO;receipt(data);[t invalidate];[NSApp terminate:nil];
  } else if(now>30){data[@"passed"]=@NO;data[@"launcher_visible_during_launch"]=@(launcherFlash);receipt(data);[t invalidate];[NSApp terminate:nil];}
 }];[NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
 });
}
