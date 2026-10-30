#import <AppKit/AppKit.h>
#include <unistd.h>
#include <dlfcn.h>
#include <SDL3/SDL.h>
// TEST ONLY. Public Cocoa input in the actual installed host/SDL client. No
// private selector, SDL interposition, Android protocol or decoder is replaced.
static NSArray<NSView*> *allViews(NSView *v) {
 if(!v)return @[];NSMutableArray *result=[NSMutableArray arrayWithObject:v];
 for(NSView *child in v.subviews)[result addObjectsFromArray:allViews(child)];return result;
}
static NSWindow *playerWindow(void) {
 for(NSWindow *window in NSApp.windows)if([window.title hasPrefix:@"DroidBridge · "])return window;return nil;
}
static void focus(NSWindow *window) {
 [window makeKeyAndOrderFront:nil];
 // Deliver the public delegate notification because a locked desktop may
 // suppress OS activation. This is client input-path evidence, not OS focus.
 if([window.delegate respondsToSelector:@selector(windowDidBecomeKey:)])
  [window.delegate windowDidBecomeKey:[NSNotification notificationWithName:NSWindowDidBecomeKeyNotification object:window]];
}
static void modifiers(NSWindow *window,NSEventModifierFlags flags,BOOL queued) {
 NSEvent *event=[NSEvent keyEventWithType:NSEventTypeFlagsChanged location:NSZeroPoint modifierFlags:flags timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber context:nil characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:55];
 if(queued)[NSApp postEvent:event atStart:NO];else [NSApp sendEvent:event];
}
static void key(NSWindow *window,NSString *characters,unsigned short code,NSEventModifierFlags flags) {
 modifiers(window,flags,NO);
 for(NSNumber *type in @[@(NSEventTypeKeyDown),@(NSEventTypeKeyUp)]) {
  NSEvent *event=[NSEvent keyEventWithType:type.unsignedIntegerValue location:NSZeroPoint modifierFlags:flags timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber context:nil characters:characters charactersIgnoringModifiers:characters isARepeat:NO keyCode:code];
  [window sendEvent:event];
 }
 modifiers(window,0,YES);
}
static BOOL click(NSWindow *window,NSDictionary *command) {
 NSView *view=window.contentView;if(!view)return NO;
 CGFloat x=[command[@"x"] doubleValue]*view.bounds.size.width,y=[command[@"y"] doubleValue]*view.bounds.size.height;
 NSPoint point=[view convertPoint:NSMakePoint(x,view.isFlipped?y:view.bounds.size.height-y) toView:nil];
 for(NSNumber *type in @[@(NSEventTypeLeftMouseDown),@(NSEventTypeLeftMouseUp)]) {
  NSEvent *event=[NSEvent mouseEventWithType:type.unsignedIntegerValue location:point modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber context:nil eventNumber:1 clickCount:1 pressure:1];
  [window sendEvent:event];
 }
 return YES;
}
static NSArray<NSPasteboardItem*> *savedClipboard;
static NSInteger clipboardOwnership=-1;
static NSString *clipboardRefusal;
static BOOL beginPaste(NSString *text) {
 NSPasteboard *pb=NSPasteboard.generalPasteboard;
 if(savedClipboard&&pb.changeCount!=clipboardOwnership){clipboardRefusal=@"Clipboard ownership changed before paste";return NO;}
 if(!savedClipboard) {
  NSInteger initialCount=pb.changeCount;
  NSMutableArray *snapshot=[NSMutableArray array];
  for(NSPasteboardItem *item in pb.pasteboardItems) {
   NSPasteboardItem *copy=[NSPasteboardItem new];
   for(NSPasteboardType type in item.types){NSData *data=[item dataForType:type];if(!data)return NO;[copy setData:data forType:type];}
   [snapshot addObject:copy];
  }
  if(pb.changeCount!=initialCount){clipboardRefusal=@"Clipboard changed during snapshot; paste was not attempted";return NO;}
  savedClipboard=snapshot;
 }
 [pb clearContents];BOOL ok=[pb setString:text forType:NSPasteboardTypeString];clipboardOwnership=pb.changeCount;return ok;
}
static BOOL restoreClipboard(void) {
 if(!savedClipboard)return YES;NSPasteboard *pb=NSPasteboard.generalPasteboard;
 if(pb.changeCount!=clipboardOwnership){clipboardRefusal=@"New clipboard content detected; prior snapshot was not restored";savedClipboard=nil;clipboardOwnership=-1;return NO;}
 [pb clearContents];BOOL ok=savedClipboard.count==0||[pb writeObjects:savedClipboard];if(ok){savedClipboard=nil;clipboardOwnership=-1;}return ok;
}
// Optional fallback when the locked host refuses Cocoa delivery. All SDL
// window/event functions run on this same client main thread; input still goes
// through the unchanged client's public event path, never its wire protocol.
static BOOL publicSDL(NSString *action,NSDictionary *command) {
 bool (*push)(SDL_Event*)=dlsym(RTLD_DEFAULT,"SDL_PushEvent");
 SDL_Window **(*windows)(int*)=dlsym(RTLD_DEFAULT,"SDL_GetWindows");
 SDL_WindowID (*identity)(SDL_Window*)=dlsym(RTLD_DEFAULT,"SDL_GetWindowID");
 bool (*size)(SDL_Window*,int*,int*)=dlsym(RTLD_DEFAULT,"SDL_GetWindowSize");
 void (*freeMemory)(void*)=dlsym(RTLD_DEFAULT,"SDL_free");
 void (*setModifiers)(SDL_Keymod)=dlsym(RTLD_DEFAULT,"SDL_SetModState");
 Uint64 (*ticks)(void)=dlsym(RTLD_DEFAULT,"SDL_GetTicksNS");
 if(!push||!windows||!identity||!size||!freeMemory||!setModifiers||!ticks)return NO;
 int count=0;SDL_Window **items=windows(&count);SDL_Window *window=count==1?items[0]:NULL;freeMemory(items);if(!window)return NO;
 SDL_WindowID target=identity(window);setModifiers(SDL_KMOD_NONE);
 if([action isEqual:@"click"]){
  int width=0,height=0;if(!size(window,&width,&height))return NO;
  for(int down=1;down>=0;down--){SDL_Event event;SDL_zero(event);event.type=down?SDL_EVENT_MOUSE_BUTTON_DOWN:SDL_EVENT_MOUSE_BUTTON_UP;event.button.timestamp=ticks();event.button.windowID=target;event.button.button=SDL_BUTTON_LEFT;event.button.down=down;event.button.clicks=1;event.button.x=[command[@"x"] doubleValue]*width;event.button.y=[command[@"y"] doubleValue]*height;if(!push(&event))return NO;}
  return YES;
 }
 if([action isEqual:@"text"]){
  static NSMutableArray *retained; if(!retained)retained=[NSMutableArray array];NSString *text=[command[@"text"] copy];[retained addObject:text];
  SDL_Event event;SDL_zero(event);event.type=SDL_EVENT_TEXT_INPUT;event.text.timestamp=ticks();event.text.windowID=target;event.text.text=text.UTF8String;return push(&event);
 }
 BOOL paste=[action isEqual:@"paste"];
 if(paste&&!beginPaste(command[@"text"]))return NO;
 if(paste||[action isEqual:@"raw_key"]){
  for(int down=1;down>=0;down--){SDL_Event event;SDL_zero(event);event.type=down?SDL_EVENT_KEY_DOWN:SDL_EVENT_KEY_UP;event.key.timestamp=ticks();event.key.windowID=target;event.key.scancode=paste?SDL_SCANCODE_V:SDL_SCANCODE_K;event.key.key=paste?SDLK_V:SDLK_K;event.key.down=down;event.key.mod=paste?SDL_KMOD_LGUI:SDL_KMOD_NONE;if(!push(&event))return NO;}
  return YES;
 }
 return NO;
}
static NSMenuItem *menuItem(NSMenu *menu,NSString *title) {
 for(NSMenuItem *item in menu.itemArray){if([item.title isEqual:title])return item;NSMenuItem *nested=menuItem(item.submenu,title);if(nested)return nested;}return nil;
}
__attribute__((constructor)) static void install(void) {
 NSString *role=nil,*executable=NSProcessInfo.processInfo.arguments.firstObject.lastPathComponent;
 if([executable isEqual:@"scrcpy"]){role=@"player";unsetenv("DYLD_INSERT_LIBRARIES");}
 else if([executable isEqual:@"DroidBridge"])role=@"host";
 else {if(![executable isEqual:@"DroidBridgeSupervisor"])unsetenv("DYLD_INSERT_LIBRARIES");return;}
 NSString *root=NSProcessInfo.processInfo.environment[@"DROIDBRIDGE_HIDDEN_IME_QA"];
 if(!root.length)return;
 dispatch_async(dispatch_get_main_queue(),^{
  __block NSInteger previous=-1;
  NSTimer *timer=[NSTimer timerWithTimeInterval:.05 repeats:YES block:^(NSTimer *timer){
   NSString *path=[root stringByAppendingPathComponent:[role stringByAppendingString:@"-command.json"]];
   NSDictionary *command=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:path]?:[NSData data] options:0 error:NULL];
   NSInteger identity=[command[@"id"] integerValue];if(!command||identity<=previous)return;
   NSString *action=command[@"action"];BOOL ok=NO;NSWindow *window=playerWindow();
   NSMutableDictionary *receipt=[@{@"id":@(identity),@"action":action?:@"",@"role":role,@"pid":@(getpid()),@"physical_focus_verified":@NO,@"main_thread":@([NSThread isMainThread])} mutableCopy];
   if([action isEqual:@"status"])ok=[role isEqual:@"host"]||window!=nil;
   else if([action isEqual:@"quit"])ok=YES;
   else if([action isEqual:@"menu"]){NSMenuItem *item=menuItem(NSApp.mainMenu,command[@"title"]);if(item){[item.menu performActionForItemAtIndex:[item.menu indexOfItem:item]];ok=YES;}}
   else if([action isEqual:@"restore_clipboard"])ok=restoreClipboard();
   else if(window) {
    focus(window);modifiers(window,0,NO);
    BOOL sdl=[NSProcessInfo.processInfo.environment[@"DROIDBRIDGE_HIDDEN_INPUT"] isEqual:@"sdl"];
    if(sdl&&[@[@"click",@"text",@"raw_key",@"paste"] containsObject:action]){ok=publicSDL(action,command);receipt[@"input_path"]=@"public SDL event queue";}
    else if([action isEqual:@"resize"]){[window setContentSize:NSMakeSize([command[@"width"] doubleValue],[command[@"height"] doubleValue])];ok=YES;}
    else if([action isEqual:@"click"])ok=click(window,command);
    else if([action isEqual:@"text"]){
     id client=nil;for(NSView *view in allViews(window.contentView))if([view respondsToSelector:@selector(insertText:replacementRange:)]){client=view;break;}
     if(!client&&[window.firstResponder respondsToSelector:@selector(insertText:replacementRange:)])client=window.firstResponder;
     if(client){[(id<NSTextInputClient>)client insertText:command[@"text"] replacementRange:NSMakeRange(NSNotFound,0)];ok=YES;receipt[@"client_class"]=NSStringFromClass([client class]);}
    }
    else if([action isEqual:@"raw_key"]){key(window,command[@"characters"]?:@"k",[command[@"keycode"] unsignedShortValue],0);ok=YES;}
    else if([action isEqual:@"paste"]){if(beginPaste(command[@"text"])){key(window,@"v",9,NSEventModifierFlagCommand);ok=YES;}}
    else if([action isEqual:@"capture"]){NSView *view=window.contentView;[view displayIfNeeded];NSBitmapImageRep *image=[view bitmapImageRepForCachingDisplayInRect:view.bounds];if(image){[view cacheDisplayInRect:view.bounds toBitmapImageRep:image];ok=[[image representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[root stringByAppendingPathComponent:command[@"filename"]] atomically:YES];}}
   }
   if(window){receipt[@"window"]=@(window.windowNumber);receipt[@"title"]=window.title?:@"";receipt[@"content_width"]=@(window.contentView.bounds.size.width);receipt[@"content_height"]=@(window.contentView.bounds.size.height);receipt[@"first_responder"]=NSStringFromClass(window.firstResponder.class)?:@"";}
   receipt[@"passed"]=@(ok);if(clipboardRefusal){receipt[@"clipboard_refusal"]=clipboardRefusal;clipboardRefusal=nil;}previous=identity;
   [[NSJSONSerialization dataWithJSONObject:receipt options:NSJSONWritingPrettyPrinted error:NULL] writeToFile:[root stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-receipt-%ld.json",role,(long)identity]] atomically:YES];
   if([action isEqual:@"quit"]){restoreClipboard();[timer invalidate];[NSApp terminate:nil];}
  }];[NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
 });
}
