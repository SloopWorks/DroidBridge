#import <AppKit/AppKit.h>
#include <stdlib.h>
// Test-only injection into the unmodified installed executable. Uses public
// AppKit views/target-actions, not private selectors or Android mock transport.
static NSArray<NSView*> *views(NSView *view) {
 if(!view)return @[];NSMutableArray *a=[NSMutableArray arrayWithObject:view];
 for(NSView *v in view.subviews)[a addObjectsFromArray:views(v)];return a;
}
static void invalidate(NSView *v){v.needsDisplay=YES;for(NSView *s in v.subviews)invalidate(s);}
static BOOL capture(NSView *v,NSString *path) {
 [v layoutSubtreeIfNeeded];invalidate(v);[v displayIfNeeded];
 NSBitmapImageRep *b=[v bitmapImageRepForCachingDisplayInRect:v.bounds];if(!b)return NO;
 [v cacheDisplayInRect:v.bounds toBitmapImageRep:b];
 return [[b representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
}
__attribute__((constructor)) static void begin(void) {
 unsetenv("DYLD_INSERT_LIBRARIES");dispatch_async(dispatch_get_main_queue(),^{
 NSString *root=NSProcessInfo.processInfo.environment[@"DROIDBRIDGE_LAUNCHER_QA_ROOT"];__block NSInteger previous=-1;
 NSTimer *timer=[NSTimer timerWithTimeInterval:.1 repeats:YES block:^(NSTimer *t){
  NSDictionary *command=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:@"command.json"]]?:[NSData data] options:0 error:NULL];
  NSInteger number=[command[@"id"] integerValue];if(!command||number<=previous)return;
  NSString *action=command[@"action"];BOOL ok=NO;
  NSWindow *launcher=nil,*chosen=nil;NSButton *launch=nil;NSTableView *table=nil;NSSearchField *search=nil;NSPopUpButton *devices=nil,*backend=nil;NSView *video=nil;
  NSMutableArray *windows=[NSMutableArray array],*texts=[NSMutableArray array];NSMutableDictionary *buttons=[NSMutableDictionary dictionary];
  for(NSWindow *w in NSApp.windows) {
   if([w.title isEqual:@"DroidBridge"])launcher=w;
   if(w.windowNumber==[command[@"window"] integerValue])chosen=w;
   [windows addObject:@{@"number":@(w.windowNumber),@"title":w.title?:@"",@"visible":@(w.visible),@"width":@(w.contentView.bounds.size.width),@"height":@(w.contentView.bounds.size.height)}];
   for(NSView *v in views(w.contentView)) {
    if([v isKindOfClass:NSButton.class]){NSButton *b=(NSButton*)v;buttons[b.title?:@""]=b;if([b.title isEqual:@"Launch App"])launch=b;}
    if([v isKindOfClass:NSSearchField.class])search=(NSSearchField*)v;
    if([v isKindOfClass:NSPopUpButton.class]){NSPopUpButton *p=(NSPopUpButton*)v;if([p.accessibilityLabel isEqual:@"Android device"])devices=p;if([p.accessibilityLabel isEqual:@"Rendering backend"])backend=p;}
    if([v isKindOfClass:NSTableView.class]&&[(NSTableView*)v tableColumnWithIdentifier:@"package"])table=(NSTableView*)v;
    if([v isKindOfClass:NSTextField.class])[texts addObject:((NSTextField*)v).stringValue?:@""];
    if(w==chosen&&[NSStringFromClass(v.class) containsString:@"AndroidVideoView"])video=v;
   }
  }
  NSMutableDictionary *enabled=[NSMutableDictionary dictionary];for(NSString *title in buttons)enabled[title]=@(((NSButton*)buttons[title]).enabled);
  NSMutableDictionary *receipt=[@{@"id":@(number),@"action":action?:@"",@"windows":windows,@"texts":texts,@"buttons":enabled,@"rows":@(table.numberOfRows),@"selected_row":@(table.selectedRow),@"device":devices.selectedItem.title?:@"",@"backend":backend.selectedItem.title?:@"",@"launch_enabled":@(launch.enabled),@"pid":@(getpid()),@"physical_focus_verified":@NO} mutableCopy];
  if([action isEqual:@"status"])ok=YES;
  else if([action isEqual:@"select_device"]){for(NSInteger i=0;i<devices.numberOfItems;i++)if([[devices itemTitleAtIndex:i] containsString:command[@"serial"]]){[devices selectItemAtIndex:i];[devices sendAction:devices.action to:devices.target];ok=YES;break;}}
  else if([action isEqual:@"search"]){search.stringValue=command[@"query"];[search.delegate controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:search]];ok=search!=nil;}
  else if([action isEqual:@"launch"]){
   NSInteger row=-1;for(NSInteger i=0;i<table.numberOfRows;i++)for(NSView *v in views([table viewAtColumn:1 row:i makeIfNecessary:YES]))if([v isKindOfClass:NSTextField.class]&&[((NSTextField*)v).stringValue isEqual:command[@"package"]])row=i;
   if(row>=0){[backend selectItemAtIndex:[command[@"backend"] isEqual:@"scrcpy"]?1:0];[table selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];if(launch.enabled){[launch performClick:nil];ok=YES;}}
  }
  else if([action isEqual:@"capture"]){NSView *v=chosen.contentView?:launcher.contentView;ok=capture(v,[root stringByAppendingPathComponent:command[@"filename"]]);}
  else if([action isEqual:@"resize"]){if(chosen){[chosen setContentSize:NSMakeSize([command[@"width"] doubleValue],[command[@"height"] doubleValue])];ok=YES;}}
  else if([action isEqual:@"close"]){if(chosen){[chosen performClose:nil];ok=YES;}}
  else if([action isEqual:@"button"]){NSButton *b=buttons[command[@"title"]];if(b.enabled&&b.target&&b.action){[b performClick:nil];ok=YES;}}
  else if([action isEqual:@"dismiss_sheet"]){if(launcher.attachedSheet){[NSApp endSheet:launcher.attachedSheet];[launcher.attachedSheet orderOut:nil];ok=YES;}}
  else if([action isEqual:@"input"]&&video){
   NSPoint local=NSMakePoint([command[@"x"] doubleValue]*video.bounds.size.width,[command[@"y"] doubleValue]*video.bounds.size.height),p=[video convertPoint:local toView:nil];
   for(NSNumber *kind in @[@(NSEventTypeLeftMouseDown),@(NSEventTypeLeftMouseUp)]){NSEvent *e=[NSEvent mouseEventWithType:kind.unsignedIntegerValue location:p modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:chosen.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];if(kind.unsignedIntegerValue==NSEventTypeLeftMouseDown)[video mouseDown:e];else [video mouseUp:e];}
   if(command[@"text"]){[video keyDown:[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:chosen.windowNumber context:nil characters:command[@"text"] charactersIgnoringModifiers:command[@"text"] isARepeat:NO keyCode:0]];}
   ok=YES;
  }
  else if([action isEqual:@"quit"])ok=YES;
  receipt[@"passed"]=@(ok);previous=number;
  [[NSJSONSerialization dataWithJSONObject:receipt options:NSJSONWritingPrettyPrinted error:NULL] writeToFile:[root stringByAppendingPathComponent:[NSString stringWithFormat:@"receipt-%ld.json",(long)number]] atomically:YES];
  if([action isEqual:@"quit"]){[t invalidate];[NSApp terminate:nil];}
 }];[NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
 });
}
