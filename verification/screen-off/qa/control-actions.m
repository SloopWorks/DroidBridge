#import <AppKit/AppKit.h>
#include <stdlib.h>
static NSArray<NSView*> *views(NSView *view){if(!view)return @[];NSMutableArray *a=[NSMutableArray arrayWithObject:view];for(NSView *v in view.subviews)[a addObjectsFromArray:views(v)];return a;}
static NSMenuItem *menuItem(NSMenu *menu,NSString *title){for(NSMenuItem *item in menu.itemArray){if([item.title isEqual:title])return item;NSMenuItem *nested=menuItem(item.submenu,title);if(nested)return nested;}return nil;}
__attribute__((constructor)) static void begin(void){unsetenv("DYLD_INSERT_LIBRARIES");dispatch_async(dispatch_get_main_queue(),^{
 NSString *root=NSProcessInfo.processInfo.environment[@"DROIDBRIDGE_QA_POWER_ROOT"];__block NSInteger previous=-1;
 NSTimer *timer=[NSTimer timerWithTimeInterval:.1 repeats:YES block:^(NSTimer *t){
  NSData *data=[NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:@"command.json"]];if(!data)return;
  NSDictionary *command=[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];NSInteger number=[command[@"id"] integerValue];if(number<=previous)return;
  NSString *action=command[@"action"];NSMutableDictionary *receipt=[@{@"id":@(number),@"action":action?:@"",@"passed":@NO,@"pid":@(getpid()),@"bundle":NSBundle.mainBundle.bundleIdentifier?:@"",@"instrumentation":@"public AppKit target/action and native view draw; physical focus not verified"} mutableCopy];
  NSButton *checkbox=nil,*launch=nil;NSTableView *table=nil;NSPopUpButton *backend=nil,*devices=nil;NSView *video=nil;
  for(NSWindow *w in NSApp.windows)for(NSView *v in views(w.contentView)){
   if([v isKindOfClass:NSButton.class]){NSButton *b=(NSButton*)v;if([b.title isEqual:@"Keep phone screen off during Mac sessions"])checkbox=b;if([b.title isEqual:@"Launch App"])launch=b;}
   if([v isKindOfClass:NSPopUpButton.class]){NSPopUpButton *p=(NSPopUpButton*)v;if([p.itemTitles containsObject:@"scrcpy fallback"])backend=p;for(NSString *title in p.itemTitles)if([title containsString:@"emulator-"])devices=p;}
   if([v isKindOfClass:NSTableView.class]&&[(NSTableView*)v tableColumnWithIdentifier:@"package"])table=(NSTableView*)v;
   if([NSStringFromClass(v.class) containsString:@"AndroidVideoView"])video=v;
  }
  receipt[@"checkbox_state"]=@(checkbox.state);receipt[@"checkbox_enabled"]=@(checkbox.enabled);receipt[@"device"]=devices.selectedItem.title?:@"";
  BOOL ok=NO;
  NSMutableArray *messages=[NSMutableArray array];for(NSWindow *w in NSApp.windows)for(NSView *v in views(w.contentView))if([v isKindOfClass:NSTextField.class]){NSString *text=((NSTextField*)v).stringValue;if([text containsString:@"phone screen"])[messages addObject:text];}receipt[@"phone_messages"]=messages;
  if([action isEqual:@"status"]){ok=YES;}
  else if([action isEqual:@"ready"]){ok=checkbox&&checkbox.enabled&&launch&&table.numberOfRows>0;}
  else if([action isEqual:@"checkbox_on"]||[action isEqual:@"checkbox_off"]){BOOL on=[action isEqual:@"checkbox_on"];if(checkbox.enabled&&checkbox.target&&checkbox.action){if(checkbox.state!=(on?NSControlStateValueOn:NSControlStateValueOff))[checkbox performClick:nil];ok=checkbox.state==(on?NSControlStateValueOn:NSControlStateValueOff);receipt[@"checkbox_state"]=@(checkbox.state);}}
  else if([action isEqual:@"menu_on"]||[action isEqual:@"menu_off"]){NSMenuItem *item=menuItem(NSApp.mainMenu,[action isEqual:@"menu_on"]?@"Turn Phone Screen On":@"Turn Phone Screen Off");if(item&&item.target&&item.action){[item.menu performActionForItemAtIndex:[item.menu indexOfItem:item]];ok=YES;}}
  else if([action isEqual:@"select_device"]){NSString *serial=command[@"serial"];[devices.window makeKeyAndOrderFront:nil];for(NSInteger i=0;i<devices.numberOfItems;i++)if([[devices itemTitleAtIndex:i] containsString:serial]){[devices selectItemAtIndex:i];[devices sendAction:devices.action to:devices.target];ok=YES;break;}receipt[@"device"]=devices.selectedItem.title?:@"";receipt[@"checkbox_state"]=@(checkbox.state);}
  else if([action isEqual:@"launch"]){NSString *package=command[@"package"];NSInteger row=-1;for(NSInteger i=0;i<table.numberOfRows;i++){NSView *cell=[table viewAtColumn:1 row:i makeIfNecessary:YES];for(NSView *v in views(cell))if([v isKindOfClass:NSTextField.class]&&[((NSTextField*)v).stringValue isEqual:package])row=i;}if(row>=0&&launch.target&&launch.action){[backend selectItemAtIndex:0];[table selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];[launch performClick:nil];ok=YES;}}
  else if([action isEqual:@"capture"]&&video){NSBitmapImageRep *bitmap=[video bitmapImageRepForCachingDisplayInRect:video.bounds];if(bitmap){[video cacheDisplayInRect:video.bounds toBitmapImageRep:bitmap];NSData *png=[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];ok=[png writeToFile:[root stringByAppendingPathComponent:command[@"filename"]] atomically:YES];receipt[@"width"]=@(bitmap.pixelsWide);receipt[@"height"]=@(bitmap.pixelsHigh);receipt[@"visible"]=@(video.window.visible);}}
  else if([action isEqual:@"quit"]){ok=YES;}
  if(!ok&&([action isEqual:@"ready"]||[action isEqual:@"capture"]))return;
  receipt[@"passed"]=@(ok);previous=number;
  [[NSJSONSerialization dataWithJSONObject:receipt options:NSJSONWritingPrettyPrinted error:NULL] writeToFile:[root stringByAppendingPathComponent:[NSString stringWithFormat:@"receipt-%ld.json",(long)number]] atomically:YES];
  if([action isEqual:@"quit"]){[t invalidate];[NSApp terminate:nil];}
 }];[NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
});}
