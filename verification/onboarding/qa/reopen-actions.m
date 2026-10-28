#import <AppKit/AppKit.h>
#include <stdlib.h>
static NSArray<NSView*> *allViews(NSView *view){if(!view)return @[];NSMutableArray *all=[NSMutableArray arrayWithObject:view];for(NSView *v in view.subviews)[all addObjectsFromArray:allViews(v)];return all;}
static NSData *pixels(NSImage *image){
 NSRect rect=NSMakeRect(0,0,512,512);CGImageRef cg=[image CGImageForProposedRect:&rect context:nil hints:nil];if(!cg)return nil;
 NSMutableData *data=[NSMutableData dataWithLength:512*512*4];CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();CGContextRef context=CGBitmapContextCreate(data.mutableBytes,512,512,8,512*4,space,(CGBitmapInfo)kCGImageAlphaPremultipliedLast);CGColorSpaceRelease(space);if(!context)return nil;CGContextDrawImage(context,CGRectMake(0,0,512,512),cg);CGContextRelease(context);return data;
}
static double difference(NSData *a,NSData *b){if(!a||!b||a.length!=b.length)return 999;const unsigned char *x=a.bytes,*y=b.bytes;double sum=0;for(NSUInteger i=0;i<a.length;i++)sum+=abs((int)x[i]-(int)y[i]);return sum/a.length;}
__attribute__((constructor))static void start(void){unsetenv("DYLD_INSERT_LIBRARIES");dispatch_async(dispatch_get_main_queue(),^{
 NSString *root=NSProcessInfo.processInfo.environment[@"DROIDBRIDGE_QA_REOPEN_ROOT"];__block NSInteger phase=0;double began=CFAbsoluteTimeGetCurrent();__block double last=began;
 void(^receipt)(NSString*)=^(NSString *step){
  NSRunningApplication *app=NSRunningApplication.currentApplication;
  NSMutableDictionary *r=[@{@"phase":step,@"bundle_id":app.bundleIdentifier?:@"",@"name":app.localizedName?:@"",@"activation_policy":@(app.activationPolicy),@"icon_valid":@(app.icon.isValid),@"pid":@(app.processIdentifier),@"elapsed":@(CFAbsoluteTimeGetCurrent()-began),@"instrumentation":@"Public NSApplicationDelegate reopen; physical focus/Cmd+Tab not verified"} mutableCopy];
  if([step isEqual:@"finished"]){
   NSString *bundle=NSBundle.mainBundle.bundlePath;
   NSImage *stored=[[NSImage alloc]initWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Contents/Resources/AndroidApp.icns"]];
   NSImage *android=[[NSImage alloc]initWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Contents/Resources/AndroidApp.png"]];
   NSImage *expected=[NSWorkspace.sharedWorkspace iconForFile:bundle];
   NSImage *generic=[NSWorkspace.sharedWorkspace iconForFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Applications/DroidBridge.app"]];
   r[@"android_icns_mean_error"]=@(difference(pixels(stored),pixels(android)));
   r[@"running_platform_mean_error"]=@(difference(pixels(app.icon),pixels(expected)));
   r[@"generic_host_difference"]=@(difference(pixels(app.icon),pixels(generic)));
   NSBitmapImageRep *bitmap=[[NSBitmapImageRep alloc]initWithData:app.icon.TIFFRepresentation];
   [[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}]writeToFile:[root stringByAppendingPathComponent:@"running-icon.png"] atomically:YES];
  }
  [[NSJSONSerialization dataWithJSONObject:r options:NSJSONWritingPrettyPrinted error:NULL] writeToFile:[root stringByAppendingPathComponent:[step stringByAppendingString:@".json"]] atomically:YES];
 };
 NSTimer *timer=[NSTimer timerWithTimeInterval:.1 repeats:YES block:^(NSTimer *t){
  if(CFAbsoluteTimeGetCurrent()-began>100){receipt(@"timeout");[t invalidate];[NSApp terminate:nil];return;}
  if(phase==0){for(NSWindow *w in NSApp.windows)for(NSView *v in allViews(w.contentView))if([v isKindOfClass:NSTextField.class]&&[((NSTextField*)v).stringValue containsString:@"This managed Android app is unavailable"]){receipt(@"denied");phase=1;return;}}
  if(phase==1&&[NSFileManager.defaultManager fileExistsAtPath:[root stringByAppendingPathComponent:@"first.trigger"]]){[(id<NSApplicationDelegate>)NSApp.delegate applicationShouldHandleReopen:NSApp hasVisibleWindows:YES];receipt(@"first_reopen");phase=2;}
  if(phase==2&&[NSFileManager.defaultManager fileExistsAtPath:[root stringByAppendingPathComponent:@"second.trigger"]]){[(id<NSApplicationDelegate>)NSApp.delegate applicationShouldHandleReopen:NSApp hasVisibleWindows:YES];receipt(@"second_reopen");phase=3;last=CFAbsoluteTimeGetCurrent();}
  if(phase==3&&CFAbsoluteTimeGetCurrent()-last>3){receipt(@"finished");[t invalidate];[NSApp terminate:nil];}
 }];[NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
});}
