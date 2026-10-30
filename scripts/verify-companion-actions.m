#import <AppKit/AppKit.h>
#include <stdlib.h>
// Test-only public AppKit automation injected into the exact installed candidate.
// No network calls, shell, pasteboard reads or private selectors.
static NSArray<NSView*> *allViews(NSView *view) { if (!view) return @[]; NSMutableArray *a=[NSMutableArray arrayWithObject:view]; for(NSView *v in view.subviews)[a addObjectsFromArray:allViews(v)];return a; }
static void dirty(NSView *v){v.needsDisplay=YES;for(NSView*s in v.subviews)dirty(s);}
static BOOL screenshot(NSView*v,NSString*path){if(!v)return NO;[v layoutSubtreeIfNeeded];dirty(v);[v displayIfNeeded];NSBitmapImageRep*b=[v bitmapImageRepForCachingDisplayInRect:v.bounds];if(!b)return NO;[v cacheDisplayInRect:v.bounds toBitmapImageRep:b];return [[b representationUsingType:NSBitmapImageFileTypePNG properties:@{}]writeToFile:path atomically:YES];}
__attribute__((constructor)) static void begin(void){unsetenv("DYLD_INSERT_LIBRARIES");dispatch_async(dispatch_get_main_queue(),^{
 NSString*root=NSProcessInfo.processInfo.environment[@"DROIDBRIDGE_COMPANION_ACTIONS"];if(!root.length)return;__block NSInteger last=-1;
 NSTimer *timer=[NSTimer timerWithTimeInterval:.1 repeats:YES block:^(NSTimer*t){
  NSString*commandPath=[root stringByAppendingPathComponent:@"command.json"];NSDictionary*c=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:commandPath]?:NSData.data options:0 error:NULL];
  if(![c isKindOfClass:NSDictionary.class]||![c[@"id"]isKindOfClass:NSNumber.class]||![c[@"action"]isKindOfClass:NSString.class]||[c[@"id"]integerValue]<=last)return;
  NSInteger number=[c[@"id"]integerValue];NSString*action=c[@"action"],*title=c[@"window"]?:@"DroidBridge Companion";NSWindow*chosen=nil;NSMutableArray*windows=[NSMutableArray array],*texts=[NSMutableArray array],*buttons=[NSMutableArray array],*fields=[NSMutableArray array];
  for(NSWindow*w in NSApp.windows){[windows addObject:@{@"title":w.title?:@"",@"number":@(w.windowNumber),@"visible":@(w.visible),@"width":@(w.contentView.bounds.size.width),@"height":@(w.contentView.bounds.size.height)}];if([w.title isEqual:title])chosen=w;}
  for(NSView*v in allViews(chosen.contentView)){
   if([v isKindOfClass:NSTextField.class]&&![v isKindOfClass:NSSecureTextField.class]){NSTextField*f=(NSTextField*)v;NSString*label=f.accessibilityLabel?:@"";if(f.editable)[fields addObject:@{@"label":label,@"value":f.stringValue?:@""}];else[texts addObject:f.stringValue?:@""];}
   if([v isKindOfClass:NSButton.class]){NSButton*b=(NSButton*)v;[buttons addObject:@{@"title":b.title?:@"",@"label":b.accessibilityLabel?:@"",@"enabled":@(b.enabled),@"state":@(b.state)}];}
  }
  BOOL ok=NO;
  if([action isEqual:@"status"])ok=YES;
  else if([action isEqual:@"show_companion"]){for(NSMenuItem*top in NSApp.mainMenu.itemArray)for(NSMenuItem*item in top.submenu.itemArray)if([item.title isEqual:@"Companion…"]){ok=[NSApp sendAction:item.action to:item.target from:item];break;}}
  else if([action isEqual:@"click"]){for(NSView*v in allViews(chosen.contentView))if([v isKindOfClass:NSButton.class]){NSButton*b=(NSButton*)v;if(([b.title isEqual:c[@"title"]]||[b.accessibilityLabel isEqual:c[@"label"]])&&b.enabled){[b performClick:nil];ok=YES;break;}}}
  else if([action isEqual:@"set_field"]){for(NSView*v in allViews(chosen.contentView))if([v isKindOfClass:NSTextField.class]&&[v.accessibilityLabel isEqual:c[@"label"]]){NSTextField*f=(NSTextField*)v;f.stringValue=c[@"value"]?:@"";if([f.delegate respondsToSelector:@selector(controlTextDidChange:)])[f.delegate controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:f]];ok=YES;break;}}
  else if([action isEqual:@"select_adb"]){for(NSView*v in allViews(chosen.contentView))if([v isKindOfClass:NSPopUpButton.class]&&[v.accessibilityLabel isEqual:@"ADB device for companion setup"]){NSPopUpButton*p=(NSPopUpButton*)v;for(NSMenuItem*item in p.itemArray)if([item.representedObject isEqual:c[@"serial"]]){[p selectItem:item];ok=YES;break;}}}
  else if([action isEqual:@"choose_file"]){for(NSWindow*w in NSApp.windows)if([w isKindOfClass:NSSavePanel.class]){NSSavePanel*p=(NSSavePanel*)w;NSString*path=c[@"path"];if([path isKindOfClass:NSString.class]&&path.isAbsolutePath){NSURL*url=[NSURL fileURLWithPath:path];p.directoryURL=url.URLByDeletingLastPathComponent;p.nameFieldStringValue=url.lastPathComponent;[p validateVisibleColumns];[p ok:nil];ok=YES;break;}}}
  else if([action isEqual:@"select_launcher_device"]){for(NSView*v in allViews(chosen.contentView))if([v isKindOfClass:NSPopUpButton.class]&&[v.accessibilityLabel isEqual:@"Android device"]){NSPopUpButton*p=(NSPopUpButton*)v;for(NSMenuItem*item in p.itemArray)if([item.title containsString:c[@"serial"]]){[p selectItem:item];[p sendAction:p.action to:p.target];ok=YES;break;}}}
  else if([action isEqual:@"select_app"]){for(NSView*v in allViews(chosen.contentView))if([v isKindOfClass:NSTableView.class]){NSTableView*table=(NSTableView*)v;for(NSInteger row=0;row<table.numberOfRows;row++)for(NSTableColumn*column in table.tableColumns)for(NSView*cell in allViews([table viewAtColumn:[table.tableColumns indexOfObject:column] row:row makeIfNecessary:YES]))if([cell isKindOfClass:NSTextField.class]&&[((NSTextField*)cell).stringValue isEqual:c[@"package"]]){[table selectRowIndexes:[NSIndexSet indexSetWithIndex:row]byExtendingSelection:NO];ok=YES;break;}}}
  else if([action isEqual:@"resize_window"]&&chosen){CGFloat width=[c[@"width"]doubleValue],height=[c[@"height"]doubleValue];if(width>=240&&height>=240&&width<=1800&&height<=1800){[chosen setContentSize:NSMakeSize(width,height)];ok=YES;}}
  else if([action isEqual:@"close_window"]&&chosen){[chosen performClose:nil];ok=YES;}
  else if([action isEqual:@"video_tap"]&&chosen){for(NSView*v in allViews(chosen.contentView))if([NSStringFromClass(v.class)containsString:@"AndroidVideoView"]){double x=[c[@"x"]doubleValue],y=[c[@"y"]doubleValue];if(x>=0&&x<=1&&y>=0&&y<=1){NSPoint p=[v convertPoint:NSMakePoint(v.bounds.size.width*x,v.bounds.size.height*y)toView:nil];for(NSNumber*kind in @[@(NSEventTypeLeftMouseDown),@(NSEventTypeLeftMouseUp)]){NSEvent*e=[NSEvent mouseEventWithType:kind.unsignedIntegerValue location:p modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:chosen.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];if(kind.unsignedIntegerValue==NSEventTypeLeftMouseDown)[v mouseDown:e];else[v mouseUp:e];}ok=YES;break;}}}
  else if([action isEqual:@"video_key"]&&chosen){for(NSView*v in allViews(chosen.contentView))if([NSStringFromClass(v.class)containsString:@"AndroidVideoView"]){NSString*text=c[@"text"]?:@"";unsigned short key=[c[@"keycode"]unsignedShortValue];for(NSNumber*kind in @[@(NSEventTypeKeyDown),@(NSEventTypeKeyUp)]){NSEvent*e=[NSEvent keyEventWithType:kind.unsignedIntegerValue location:NSZeroPoint modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:chosen.windowNumber context:nil characters:text charactersIgnoringModifiers:text isARepeat:NO keyCode:key];if(kind.unsignedIntegerValue==NSEventTypeKeyDown)[v keyDown:e];else[v keyUp:e];}ok=YES;break;}}
  else if([action isEqual:@"capture"]){NSString*name=c[@"name"];if([name isKindOfClass:NSString.class]&&[name rangeOfString:@"^[A-Za-z0-9._-]+\\.png$" options:NSRegularExpressionSearch].location!=NSNotFound)ok=screenshot(chosen.contentView,[root stringByAppendingPathComponent:name]);}
  else if([action isEqual:@"quit"]){ok=YES;dispatch_async(dispatch_get_main_queue(),^{[NSApp terminate:nil];});}
  last=number;
  // Do not retain secret-bearing command payloads in the receipt or on disk.
  if([action isEqual:@"set_field"]&&[c[@"label"]isEqual:@"Companion pairing link"])[NSFileManager.defaultManager removeItemAtPath:commandPath error:NULL];
  NSDictionary*r=@{@"id":@(number),@"action":action,@"ok":@(ok),@"windows":windows,@"texts":texts,@"buttons":buttons,@"fields":fields,@"pid":@(getpid()),@"physical_focus_verified":@NO};
  [[NSJSONSerialization dataWithJSONObject:r options:NSJSONWritingPrettyPrinted error:NULL]writeToFile:[root stringByAppendingPathComponent:@"receipt.json"]atomically:YES];
 }];
 [[NSRunLoop mainRunLoop]addTimer:timer forMode:NSRunLoopCommonModes];
 [[NSRunLoop mainRunLoop]addTimer:timer forMode:NSModalPanelRunLoopMode];
});}
