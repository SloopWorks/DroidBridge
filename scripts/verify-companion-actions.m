#import <AppKit/AppKit.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>
#include <string.h>
// Test-only public AppKit automation injected into the exact installed candidate.
// No network calls, shell or private selectors. Explicit clipboard probes retain
// the prior pasteboard only in memory and restore it without recording its bytes.
static NSArray<NSView*> *allViews(NSView *view) { if (!view) return @[]; NSMutableArray *a=[NSMutableArray arrayWithObject:view]; for(NSView *v in view.subviews)[a addObjectsFromArray:allViews(v)];return a; }
// The unified workspace title changes with its destination. Identify its real
// sidebar, and include public toolbar item views when locating global controls.
static NSArray<NSView*> *windowViews(NSWindow *window) {
 NSMutableOrderedSet *views=[NSMutableOrderedSet orderedSetWithArray:allViews(window.contentView)];
 for(NSToolbarItem *item in window.toolbar.items)if(item.view)[views addObjectsFromArray:allViews(item.view)];
 return views.array;
}
static BOOL workspaceWindow(NSWindow *window) {
 for(NSView *view in allViews(window.contentView))if([view isKindOfClass:NSTableView.class]&&[view.accessibilityLabel isEqual:@"Workspace sections"])return YES;
 return NO;
}
static BOOL menuAction(NSString *menuTitle, NSString *itemTitle) {
 for(NSMenuItem *top in NSApp.mainMenu.itemArray)if([top.title isEqual:menuTitle])for(NSMenuItem *item in top.submenu.itemArray)if([item.title isEqual:itemTitle]&&item.action)return [NSApp sendAction:item.action to:item.target from:item];
 return NO;
}
static BOOL containsSerial(NSString *title, NSString *serial) {
 NSString *pattern=[NSString stringWithFormat:@"(^|[^A-Za-z0-9._:-])%@($|[^A-Za-z0-9._:-])",[NSRegularExpression escapedPatternForString:serial]];
 return [title rangeOfString:pattern options:NSRegularExpressionSearch].location!=NSNotFound;
}
// Navigation completes only after foreground/key-window admission and the
// shipping menu handler's observable destination on the following main turn.
static void navigationReceipt(NSString *root, NSInteger number, NSString *action, NSWindow *chosen, BOOL verified) {
 NSMutableArray *windows=[NSMutableArray array],*texts=[NSMutableArray array],*buttons=[NSMutableArray array],*fields=[NSMutableArray array];
 for(NSWindow *w in NSApp.windows)[windows addObject:@{@"title":w.title?:@"",@"number":@(w.windowNumber),@"visible":@(w.visible),@"workspace_host":@(workspaceWindow(w)),@"width":@(w.contentView.bounds.size.width),@"height":@(w.contentView.bounds.size.height)}];
 for(NSView *view in windowViews(chosen)) {
  if(view.isHiddenOrHasHiddenAncestor)continue;
  if([view isKindOfClass:NSTextField.class]&&![view isKindOfClass:NSSecureTextField.class]){NSTextField *field=(NSTextField*)view;NSString *label=field.accessibilityLabel?:@"";if(field.editable)[fields addObject:@{@"label":label,@"value":[label isEqual:@"Companion pairing link"]?@"<private>":field.stringValue?:@""}];else[texts addObject:field.stringValue?:@""];}
  if([view isKindOfClass:NSButton.class]){NSButton *button=(NSButton*)view;[buttons addObject:@{@"title":button.title?:@"",@"label":button.accessibilityLabel?:@"",@"enabled":@(button.enabled),@"state":@(button.state)}];}
 }
 NSDictionary *receipt=@{@"id":@(number),@"action":action,@"ok":@(verified),@"route_verified":@(verified),@"windows":windows,@"texts":texts,@"buttons":buttons,@"fields":fields,@"pid":@(getpid()),@"chosen_window":chosen?@(chosen.windowNumber):NSNull.null,@"physical_focus_verified":@NO};
 [[NSJSONSerialization dataWithJSONObject:receipt options:NSJSONWritingPrettyPrinted error:NULL]writeToFile:[root stringByAppendingPathComponent:@"receipt.json"]atomically:YES];
}
static void dirty(NSView *v){v.needsDisplay=YES;for(NSView*s in v.subviews)dirty(s);}
static BOOL screenshot(NSView*v,NSString*path){if(!v)return NO;[v layoutSubtreeIfNeeded];dirty(v);[v displayIfNeeded];NSBitmapImageRep*b=[v bitmapImageRepForCachingDisplayInRect:v.bounds];if(!b)return NO;[v cacheDisplayInRect:v.bounds toBitmapImageRep:b];return [[b representationUsingType:NSBitmapImageFileTypePNG properties:@{}]writeToFile:path atomically:YES];}
__attribute__((constructor)) static void begin(void){unsetenv("DYLD_INSERT_LIBRARIES");dispatch_async(dispatch_get_main_queue(),^{
 NSString*root=NSProcessInfo.processInfo.environment[@"DROIDBRIDGE_COMPANION_ACTIONS"];
 if(!root.length){fprintf(stderr,"QA observer refused: missing_scope_environment\n");return;}
 NSArray<NSString*> *arguments=NSProcessInfo.processInfo.arguments;NSUInteger rootIndex=[arguments indexOfObject:@"--companion-qa-root"],serialIndex=[arguments indexOfObject:@"--serial"],rootFlags=0,serialFlags=0;
 for(NSString *argument in arguments){if([argument isEqual:@"--companion-qa-root"])rootFlags++;if([argument isEqual:@"--serial"])serialFlags++;}
 if(rootFlags!=1||serialFlags!=1||rootIndex==NSNotFound||serialIndex==NSNotFound||rootIndex+1>=arguments.count||serialIndex+1>=arguments.count||![arguments[rootIndex+1]isEqual:root]){fprintf(stderr,"QA observer refused: scope_arguments_mismatch\n");return;}
 NSString *qaSerial=arguments[serialIndex+1];struct stat metadata;
 if(![@[@"emulator-5580",@"emulator-5582"]containsObject:qaSerial]){fprintf(stderr,"QA observer refused: serial_outside_qa_cohort\n");return;}
 if(!root.isAbsolutePath||[root lengthOfBytesUsingEncoding:NSUTF8StringEncoding]>2048||lstat(root.fileSystemRepresentation,&metadata)!=0||!S_ISDIR(metadata.st_mode)||metadata.st_uid!=geteuid()||(metadata.st_mode&0777)!=0700){fprintf(stderr,"QA observer refused: invalid_private_root_metadata\n");return;}
 // Foundation normalizes /private/tmp to /tmp. Match CompanionQAScope's
 // POSIX canonical-path contract exactly instead of accepting an alias.
 char *resolved=realpath(root.fileSystemRepresentation,NULL);
 BOOL canonical=resolved&&strcmp(resolved,root.fileSystemRepresentation)==0;free(resolved);
 if(!canonical){fprintf(stderr,"QA observer refused: noncanonical_private_root\n");return;}
 fprintf(stderr,"QA observer ready: isolated_scope_validated\n");fflush(stderr);
 __block BOOL navigationPending=NO;
 __block NSInteger last=-1;__block NSArray<NSPasteboardItem*>*savedPasteboard=nil;__block NSString*probeText=nil;
 NSTimer *timer=[NSTimer timerWithTimeInterval:.1 repeats:YES block:^(NSTimer*t){
  if(navigationPending)return;
  NSString*commandPath=[root stringByAppendingPathComponent:@"command.json"];NSDictionary*c=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:commandPath]?:NSData.data options:0 error:NULL];
  if(![c isKindOfClass:NSDictionary.class]||![c[@"id"]isKindOfClass:NSNumber.class]||![c[@"action"]isKindOfClass:NSString.class]||[c[@"id"]integerValue]<=last)return;
  NSInteger number=[c[@"id"]integerValue];NSString*action=c[@"action"],*title=[c[@"window"]isKindOfClass:NSString.class]?c[@"window"]:nil;BOOL useWorkspace=!title||[title isEqual:@"DroidBridge"];NSWindow*chosen=nil;NSMutableArray*windows=[NSMutableArray array],*texts=[NSMutableArray array],*buttons=[NSMutableArray array],*fields=[NSMutableArray array];
  for(NSWindow*w in NSApp.windows){[windows addObject:@{@"title":w.title?:@"",@"number":@(w.windowNumber),@"visible":@(w.visible),@"workspace_host":@(workspaceWindow(w)),@"width":@(w.contentView.bounds.size.width),@"height":@(w.contentView.bounds.size.height)}];if((useWorkspace&&workspaceWindow(w))||(!useWorkspace&&[w.title isEqual:title]))chosen=w;}
  for(NSView*v in windowViews(chosen)){
   if(v.isHiddenOrHasHiddenAncestor)continue;
   if([v isKindOfClass:NSTextField.class]&&![v isKindOfClass:NSSecureTextField.class]){NSTextField*f=(NSTextField*)v;NSString*label=f.accessibilityLabel?:@"";if(f.editable)[fields addObject:@{@"label":label,@"value":[label isEqual:@"Companion pairing link"]?@"<private>":f.stringValue?:@""}];else[texts addObject:f.stringValue?:@""];}
   if([v isKindOfClass:NSButton.class]){NSButton*b=(NSButton*)v;[buttons addObject:@{@"title":b.title?:@"",@"label":b.accessibilityLabel?:@"",@"enabled":@(b.enabled),@"state":@(b.state)}];}
  }
  BOOL ok=NO;
  if([action isEqual:@"status"])ok=YES;
  else if([action isEqual:@"clipboard_save"]){NSMutableArray*items=[NSMutableArray array];for(NSPasteboardItem*item in NSPasteboard.generalPasteboard.pasteboardItems){NSPasteboardItem*copy=[NSPasteboardItem new];for(NSPasteboardType type in item.types){NSData*data=[item dataForType:type];if(data)[copy setData:data forType:type];}[items addObject:copy];}savedPasteboard=items;probeText=[c[@"expected"]isKindOfClass:NSString.class]?c[@"expected"]:nil;ok=YES;}
  else if([action isEqual:@"clipboard_matches"]){NSString*expected=c[@"expected"];ok=[expected isKindOfClass:NSString.class]&&[[NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString]isEqual:expected];if(ok)probeText=expected;}
  else if([action isEqual:@"clipboard_restore"]){if(savedPasteboard&&probeText&&[[NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString]isEqual:probeText]){[NSPasteboard.generalPasteboard clearContents];[NSPasteboard.generalPasteboard writeObjects:savedPasteboard];}savedPasteboard=nil;probeText=nil;ok=YES;}
  else if([action isEqual:@"navigate"]||[action isEqual:@"show_companion"]){
   NSString *section=c[@"section"]?:c[@"title"];NSDictionary *routes=@{@"apps":@[@"View",@"Apps"],@"sessions":@[@"View",@"Sessions"],@"handoff":@[@"View",@"Handoff"],@"notifications":@[@"View",@"Notifications"],@"devices":@[@"View",@"Devices"],@"deviceSettings":@[@"Devices",@"Device Settings…"],@"diagnostics":@[@"Help",@"Diagnostics…"],@"delivery":@[@"Help",@"Release Information…"]};
   NSArray *route=[action isEqual:@"show_companion"]?@[@"Devices",@"Connection and Pairing…"]:routes[section];
   if(!route)for(NSArray *candidate in routes.allValues)if([candidate[1]isEqual:section]){route=candidate;break;}
   if(route&&workspaceWindow(chosen)){
    navigationPending=YES;last=number;
    NSString *expected=[action isEqual:@"show_companion"]?@"Devices":[route[1]stringByReplacingOccurrencesOfString:@"…" withString:@""];
    __block NSUInteger activationAttempts=0;
    void (^finishNavigation)(BOOL)=^(BOOL dispatched){
     BOOL reached=dispatched&&workspaceWindow(chosen)&&chosen.visible&&[chosen.title isEqual:expected];
     navigationReceipt(root,number,action,chosen,reached);navigationPending=NO;
    };
    NSTimer *admission=[NSTimer timerWithTimeInterval:.05 repeats:YES block:^(NSTimer *poll){
     [NSApp activateIgnoringOtherApps:YES];[chosen makeKeyAndOrderFront:nil];
     if(!NSApp.active||!chosen.keyWindow){
      if(++activationAttempts<40)return;
      [poll invalidate];finishNavigation(NO);return;
     }
     [poll invalidate];BOOL dispatched=menuAction(route[0],route[1]);
     dispatch_async(dispatch_get_main_queue(),^{finishNavigation(dispatched);});
    }];
    // Activation may complete asynchronously after another app owned focus.
    [NSApp activateIgnoringOtherApps:YES];[chosen makeKeyAndOrderFront:nil];
    [[NSRunLoop mainRunLoop]addTimer:admission forMode:NSRunLoopCommonModes];
    [[NSRunLoop mainRunLoop]addTimer:admission forMode:NSModalPanelRunLoopMode];return;
   }
  }
  else if([action isEqual:@"click"]){for(NSView*v in windowViews(chosen))if(!v.isHiddenOrHasHiddenAncestor&&[v isKindOfClass:NSButton.class]){NSButton*b=(NSButton*)v;if(([b.title isEqual:c[@"title"]]||[b.accessibilityLabel isEqual:c[@"label"]])&&b.enabled){[b performClick:nil];ok=YES;break;}}}
  else if([action isEqual:@"click_async"]){for(NSView*v in windowViews(chosen))if(!v.isHiddenOrHasHiddenAncestor&&[v isKindOfClass:NSButton.class]){NSButton*b=(NSButton*)v;if(([b.title isEqual:c[@"title"]]||[b.accessibilityLabel isEqual:c[@"label"]])&&b.enabled){dispatch_async(dispatch_get_main_queue(),^{[b performClick:nil];});ok=YES;break;}}}
  else if([action isEqual:@"set_field"]){for(NSView*v in windowViews(chosen))if(!v.isHiddenOrHasHiddenAncestor&&[v isKindOfClass:NSTextField.class]&&[v.accessibilityLabel isEqual:c[@"label"]]){NSTextField*f=(NSTextField*)v;f.stringValue=c[@"value"]?:@"";if([f.delegate respondsToSelector:@selector(controlTextDidChange:)])[f.delegate controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:f]];ok=YES;break;}}
  else if([action isEqual:@"select_adb"]||[action isEqual:@"select_launcher_device"]){
   NSString *serial=c[@"serial"];
   if([serial isEqual:qaSerial])for(NSView*v in windowViews(chosen))if(!v.isHiddenOrHasHiddenAncestor&&[v isKindOfClass:NSPopUpButton.class]&&[v.accessibilityLabel isEqual:@"Android device"]){NSPopUpButton*p=(NSPopUpButton*)v;for(NSMenuItem*item in p.itemArray)if([item.representedObject isEqual:serial]||containsSerial(item.title,serial)){[p selectItem:item];ok=p.action&&[p sendAction:p.action to:p.target];break;}if(ok)break;}
  }
  else if([action isEqual:@"choose_file"]){for(NSWindow*w in NSApp.windows)if([w isKindOfClass:NSSavePanel.class]){NSSavePanel*p=(NSSavePanel*)w;NSString*path=c[@"path"];if([path isKindOfClass:NSString.class]&&path.isAbsolutePath){NSURL*url=[NSURL fileURLWithPath:path];p.directoryURL=url.URLByDeletingLastPathComponent;p.nameFieldStringValue=url.lastPathComponent;[p validateVisibleColumns];[p ok:nil];ok=YES;break;}}}
  else if([action isEqual:@"select_app"]){for(NSView*v in windowViews(chosen))if(!v.isHiddenOrHasHiddenAncestor&&[v isKindOfClass:NSTableView.class]&&[v.accessibilityLabel isEqual:@"Installed Android applications"]){NSTableView*table=(NSTableView*)v;for(NSInteger row=0;row<table.numberOfRows;row++)for(NSTableColumn*column in table.tableColumns)for(NSView*cell in allViews([table viewAtColumn:[table.tableColumns indexOfObject:column] row:row makeIfNecessary:YES]))if([cell isKindOfClass:NSTextField.class]&&[((NSTextField*)cell).stringValue isEqual:c[@"package"]]){[table selectRowIndexes:[NSIndexSet indexSetWithIndex:row]byExtendingSelection:NO];ok=YES;break;}}}
  else if([action isEqual:@"resize_window"]&&chosen){CGFloat width=[c[@"width"]doubleValue],height=[c[@"height"]doubleValue];if(width>=240&&height>=240&&width<=1800&&height<=1800){[chosen setContentSize:NSMakeSize(width,height)];ok=YES;}}
  else if([action isEqual:@"close_window"]&&chosen){[chosen performClose:nil];ok=YES;}
  else if([action isEqual:@"video_tap"]&&chosen){for(NSView*v in windowViews(chosen))if([NSStringFromClass(v.class)containsString:@"AndroidVideoView"]){double x=[c[@"x"]doubleValue],y=[c[@"y"]doubleValue];if(x>=0&&x<=1&&y>=0&&y<=1){NSPoint p=[v convertPoint:NSMakePoint(v.bounds.size.width*x,v.bounds.size.height*y)toView:nil];for(NSNumber*kind in @[@(NSEventTypeLeftMouseDown),@(NSEventTypeLeftMouseUp)]){NSEvent*e=[NSEvent mouseEventWithType:kind.unsignedIntegerValue location:p modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:chosen.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];if(kind.unsignedIntegerValue==NSEventTypeLeftMouseDown)[v mouseDown:e];else[v mouseUp:e];}ok=YES;break;}}}
  else if([action isEqual:@"video_key"]&&chosen){for(NSView*v in windowViews(chosen))if([NSStringFromClass(v.class)containsString:@"AndroidVideoView"]){NSString*text=c[@"text"]?:@"";unsigned short key=[c[@"keycode"]unsignedShortValue];for(NSNumber*kind in @[@(NSEventTypeKeyDown),@(NSEventTypeKeyUp)]){NSEvent*e=[NSEvent keyEventWithType:kind.unsignedIntegerValue location:NSZeroPoint modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:chosen.windowNumber context:nil characters:text charactersIgnoringModifiers:text isARepeat:NO keyCode:key];if(kind.unsignedIntegerValue==NSEventTypeKeyDown)[v keyDown:e];else[v keyUp:e];}ok=YES;break;}}
  else if([action isEqual:@"capture"]){NSString*name=c[@"name"];if([name isKindOfClass:NSString.class]&&[name rangeOfString:@"^[A-Za-z0-9._-]+\\.png$" options:NSRegularExpressionSearch].location!=NSNotFound)ok=screenshot(chosen.contentView,[root stringByAppendingPathComponent:name]);}
  else if([action isEqual:@"quit"]){ok=YES;[NSApp performSelector:@selector(terminate:) withObject:nil afterDelay:.05];}
  last=number;
  // Do not retain secret-bearing command payloads in the receipt or on disk.
  if([action isEqual:@"set_field"]&&[c[@"label"]isEqual:@"Companion pairing link"])[NSFileManager.defaultManager removeItemAtPath:commandPath error:NULL];
  NSDictionary*r=@{@"id":@(number),@"action":action,@"ok":@(ok),@"windows":windows,@"texts":texts,@"buttons":buttons,@"fields":fields,@"pid":@(getpid()),@"chosen_window":chosen?@(chosen.windowNumber):NSNull.null,@"physical_focus_verified":@NO};
  [[NSJSONSerialization dataWithJSONObject:r options:NSJSONWritingPrettyPrinted error:NULL]writeToFile:[root stringByAppendingPathComponent:@"receipt.json"]atomically:YES];
 }];
 [[NSRunLoop mainRunLoop]addTimer:timer forMode:NSRunLoopCommonModes];
 [[NSRunLoop mainRunLoop]addTimer:timer forMode:NSModalPanelRunLoopMode];
});}
