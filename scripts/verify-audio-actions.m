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
 if(!v || !path.length)return NO;
 [v layoutSubtreeIfNeeded];invalidate(v);[v displayIfNeeded];
 NSBitmapImageRep *b=[v bitmapImageRepForCachingDisplayInRect:v.bounds];if(!b)return NO;
 [v cacheDisplayInRect:v.bounds toBitmapImageRep:b];
 return [[b representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
}
// This fixture intentionally never reads or writes the clipboard.
static NSMenu *audioMenu(void) {
 for (NSMenuItem *item in NSApp.mainMenu.itemArray) {
  if ([item.title isEqual:@"Audio"] || [item.submenu.title isEqual:@"Audio"]) return item.submenu;
 }
 return nil;
}
static void refreshAudioMenu(NSMenu *menu) {
 if (!menu) return;
 id<NSMenuDelegate> delegate=menu.delegate;
 if ([delegate respondsToSelector:@selector(menuNeedsUpdate:)]) [delegate menuNeedsUpdate:menu];
 [menu update];
}
static NSArray *menuReceipt(NSMenu *menu) {
 NSMutableArray *items=[NSMutableArray array];
 for(NSMenuItem *item in menu.itemArray) {
  NSString *route=[item.representedObject isKindOfClass:NSString.class]?item.representedObject:@"";
  [items addObject:@{@"title":item.title?:@"",@"enabled":@(item.enabled),@"state":@(item.state),@"route":route,@"separator":@(item.separatorItem)}];
 }
 return items;
}
static BOOL validRoute(id route) {
 return [route isKindOfClass:NSString.class] && [@[@"phone",@"mac",@"macAndPhone"] containsObject:route];
}
__attribute__((constructor)) static void begin(void) {
 unsetenv("DYLD_INSERT_LIBRARIES");dispatch_async(dispatch_get_main_queue(),^{
 NSString *root=NSProcessInfo.processInfo.environment[@"DROIDBRIDGE_LAUNCHER_QA_ROOT"];if(!root.length)return;__block NSInteger previous=-1;
 NSTimer *timer=[NSTimer timerWithTimeInterval:.1 repeats:YES block:^(NSTimer *t){
  NSDictionary *command=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:@"command.json"]]?:[NSData data] options:0 error:NULL];
  if(![command isKindOfClass:NSDictionary.class] || ![command[@"id"] isKindOfClass:NSNumber.class] || ![command[@"action"] isKindOfClass:NSString.class])return;
  NSInteger number=[command[@"id"] integerValue];if(number<=previous)return;
  NSString *action=command[@"action"];BOOL ok=NO;
  NSWindow *launcher=nil,*chosen=nil;NSButton *launch=nil;NSTableView *table=nil;NSSearchField *search=nil;NSPopUpButton *devices=nil,*backend=nil,*audioRoute=nil;NSTextField *audioStatus=nil;NSView *video=nil;
  NSMutableArray *windows=[NSMutableArray array],*texts=[NSMutableArray array];NSMutableDictionary *buttons=[NSMutableDictionary dictionary];
  for(NSWindow *w in NSApp.windows) {
   if([w.title isEqual:@"DroidBridge"])launcher=w;
   if(w.windowNumber==[command[@"window"] integerValue])chosen=w;
   [windows addObject:@{@"number":@(w.windowNumber),@"title":w.title?:@"",@"visible":@(w.visible),@"minimized":@(w.miniaturized),@"key":@(w.keyWindow),@"width":@(w.contentView.bounds.size.width),@"height":@(w.contentView.bounds.size.height)}];
   for(NSView *v in views(w.contentView)) {
    if([v isKindOfClass:NSButton.class]){NSButton *b=(NSButton*)v;buttons[b.title?:@""]=b;if([b.title isEqual:@"Launch App"])launch=b;}
    if([v isKindOfClass:NSSearchField.class])search=(NSSearchField*)v;
    if([v isKindOfClass:NSPopUpButton.class]){NSPopUpButton *p=(NSPopUpButton*)v;if([p.accessibilityLabel isEqual:@"Android device"])devices=p;if([p.accessibilityLabel isEqual:@"Rendering backend"])backend=p;if([p.accessibilityLabel isEqual:@"Device audio route"])audioRoute=p;}
    if([v isKindOfClass:NSTableView.class]&&[(NSTableView*)v tableColumnWithIdentifier:@"package"])table=(NSTableView*)v;
    if([v isKindOfClass:NSTextField.class]){[texts addObject:((NSTextField*)v).stringValue?:@""];if([v.accessibilityLabel isEqual:@"Device audio status"])audioStatus=(NSTextField*)v;}
    if(w==chosen&&[NSStringFromClass(v.class) containsString:@"AndroidVideoView"])video=v;
   }
  }
  NSMutableDictionary *enabled=[NSMutableDictionary dictionary],*states=[NSMutableDictionary dictionary];for(NSString *title in buttons){enabled[title]=@(((NSButton*)buttons[title]).enabled);states[title]=@(((NSButton*)buttons[title]).state);}
  NSMutableDictionary *receipt=[@{@"id":@(number),@"action":action?:@"",@"windows":windows,@"texts":texts,@"buttons":enabled,@"button_states":states,@"rows":@(table.numberOfRows),@"selected_row":@(table.selectedRow),@"device":devices.selectedItem.title?:@"",@"backend":backend.selectedItem.title?:@"",@"launch_enabled":@(launch.enabled),@"pid":@(getpid()),@"physical_focus_verified":@NO} mutableCopy];
  if([action isEqual:@"status"])ok=YES;
  else if([action isEqual:@"select_device"]){for(NSInteger i=0;i<devices.numberOfItems;i++)if([[devices itemTitleAtIndex:i] containsString:command[@"serial"]]){[devices selectItemAtIndex:i];[devices sendAction:devices.action to:devices.target];ok=YES;break;}}
  else if([action isEqual:@"search"]){search.stringValue=command[@"query"];[search.delegate controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:search]];ok=search!=nil;}
  else if([action isEqual:@"launch"]){
   NSInteger row=-1;for(NSInteger i=0;i<table.numberOfRows;i++)for(NSView *v in views([table viewAtColumn:1 row:i makeIfNecessary:YES]))if([v isKindOfClass:NSTextField.class]&&[((NSTextField*)v).stringValue isEqual:command[@"package"]])row=i;
   if(row>=0){[backend selectItemAtIndex:[command[@"backend"] isEqual:@"scrcpy"]?1:0];[table selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];if(launch.enabled){[launch performClick:nil];ok=YES;}}
  }
  else if([action isEqual:@"route"]){
   id value=command[@"value"];if(validRoute(value)&&audioRoute.enabled&&audioRoute.target&&audioRoute.action){
    for(NSMenuItem *item in audioRoute.itemArray)if([item.representedObject isEqual:value]&&item.enabled){
     [audioRoute selectItem:item];ok=[audioRoute sendAction:audioRoute.action to:audioRoute.target];break;
    }
   }
  }
  else if([action isEqual:@"audio_menu"]){
   NSMenu *menu=audioMenu();refreshAudioMenu(menu);id value=command[@"value"];
   if(!value && [command[@"title"] isKindOfClass:NSString.class]){
    for(NSMenuItem *item in menu.itemArray)if([item.title isEqual:command[@"title"]]&&item.enabled&&item.action){
     [menu performActionForItemAtIndex:[menu indexOfItem:item]];ok=YES;break;
    }
   }
   else if(!value)ok=menu!=nil;
   else if(validRoute(value))for(NSMenuItem *item in menu.itemArray)if([item.representedObject isEqual:value]&&item.enabled&&item.action){
    [menu performActionForItemAtIndex:[menu indexOfItem:item]];ok=YES;break;
   }
  }
  else if([action isEqual:@"backend"]){
   NSString *value=command[@"value"]?:command[@"backend"];
   if(backend.enabled&&([value isEqual:@"native"]||[value isEqual:@"scrcpy"])){[backend selectItemAtIndex:[value isEqual:@"scrcpy"]?1:0];if(backend.action)[backend sendAction:backend.action to:backend.target];ok=YES;}
  }
  else if([action isEqual:@"package"]){
   for(NSInteger i=0;i<table.numberOfRows;i++)for(NSView *v in views([table viewAtColumn:1 row:i makeIfNecessary:YES]))if([v isKindOfClass:NSTextField.class]&&[((NSTextField*)v).stringValue isEqual:command[@"package"]]){[table selectRowIndexes:[NSIndexSet indexSetWithIndex:i] byExtendingSelection:NO];ok=YES;}
  }
  else if([action isEqual:@"capture"]){NSView *v=chosen.contentView?:launcher.contentView;ok=capture(v,[root stringByAppendingPathComponent:command[@"filename"]]);}
  else if([action isEqual:@"resize"]){if(chosen){[chosen setContentSize:NSMakeSize([command[@"width"] doubleValue],[command[@"height"] doubleValue])];ok=YES;}}
  else if([action isEqual:@"close"]){if(chosen){[chosen performClose:nil];ok=YES;}}
  else if([action isEqual:@"button"]){NSButton *b=buttons[command[@"title"]];if(b.enabled&&b.target&&b.action){[b performClick:nil];ok=YES;}}
  else if([action isEqual:@"dismiss_sheet"]){if(launcher.attachedSheet){[NSApp endSheet:launcher.attachedSheet];[launcher.attachedSheet orderOut:nil];ok=YES;}}
  else if([action isEqual:@"input"]&&video){
   double x=[command[@"x"] doubleValue], y=[command[@"y"] doubleValue];
   NSPoint local=NSMakePoint(x*video.bounds.size.width,(video.isFlipped?y:1-y)*video.bounds.size.height),p=[video convertPoint:local toView:nil];
   for(NSNumber *kind in @[@(NSEventTypeLeftMouseDown),@(NSEventTypeLeftMouseUp)]){NSEvent *e=[NSEvent mouseEventWithType:kind.unsignedIntegerValue location:p modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:chosen.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];if(kind.unsignedIntegerValue==NSEventTypeLeftMouseDown)[video mouseDown:e];else [video mouseUp:e];}
   if(command[@"text"]){[video keyDown:[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:chosen.windowNumber context:nil characters:command[@"text"] charactersIgnoringModifiers:command[@"text"] isARepeat:NO keyCode:0]];}
   ok=YES;
  }
  else if([action isEqual:@"raw_key"]&&video){
   unsigned short code=[command[@"keycode"] unsignedShortValue];NSString *chars=command[@"characters"]?:@"";
   NSEventModifierFlags flags=[command[@"command"] boolValue]?NSEventModifierFlagCommand:0;
   for(NSNumber *kind in @[@(NSEventTypeKeyDown),@(NSEventTypeKeyUp)]){
    NSEvent *e=[NSEvent keyEventWithType:kind.unsignedIntegerValue location:NSZeroPoint modifierFlags:flags timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:chosen.windowNumber context:nil characters:chars charactersIgnoringModifiers:chars isARepeat:NO keyCode:code];
    if(kind.unsignedIntegerValue==NSEventTypeKeyDown)[video keyDown:e];else [video keyUp:e];
   }ok=YES;
  }
  else if([action isEqual:@"quit"])ok=YES;
  // Read after target/action delivery so requested selection is current. Router
  // work remains asynchronous; the driver polls status for eventual outcomes.
  NSMenu *menu=audioMenu();refreshAudioMenu(menu);
  NSArray *items=menuReceipt(menu);
  receipt[@"audio_menu"]=items;receipt[@"menus"]=@{@"Audio":items};
  receipt[@"audio_status"]=audioStatus.stringValue?:@"";
  receipt[@"audio_route"]=[audioRoute.selectedItem.representedObject isKindOfClass:NSString.class]?audioRoute.selectedItem.representedObject:@"";
  receipt[@"passed"]=@(ok);previous=number;
  [[NSJSONSerialization dataWithJSONObject:receipt options:NSJSONWritingPrettyPrinted error:NULL] writeToFile:[root stringByAppendingPathComponent:[NSString stringWithFormat:@"receipt-%ld.json",(long)number]] atomically:YES];
  if([action isEqual:@"quit"]){[t invalidate];[NSApp terminate:nil];}
 }];[NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
 });
}
