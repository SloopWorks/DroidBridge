#import <AppKit/AppKit.h>
// Test-only injection into the owned Player's public Cocoa event queue. Android
// capture, decode, rendering and scrcpy input processing remain unmodified.
static void later(NSTimeInterval delay, void (^action)(void)) {
    NSTimer *timer = [NSTimer timerWithTimeInterval:delay repeats:NO block:^(NSTimer *unused){(void)unused;action();}];
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
}
static id text_client(NSView *view) {
    fprintf(stderr,"[QA] view class=%s insertText=%d\n",NSStringFromClass(view.class).UTF8String,[view respondsToSelector:@selector(insertText:replacementRange:)]);
    if([view respondsToSelector:@selector(insertText:replacementRange:)])return view;
    for(NSView *child in view.subviews){id found=text_client(child);if(found)return found;}
    return nil;
}
static void click(NSWindow *window, CGFloat androidY) {
    NSView *view=window.contentView;NSRect bounds=view.bounds;
    CGFloat y=androidY/1080.0*bounds.size.height;
    NSPoint inView=NSMakePoint(bounds.size.width*0.5,view.isFlipped?y:bounds.size.height-y);
    NSPoint point=[view convertPoint:inView toView:nil];
    for(NSNumber *kind in @[@(NSEventTypeLeftMouseDown),@(NSEventTypeLeftMouseUp)]) {
        NSEvent *event=[NSEvent mouseEventWithType:kind.unsignedIntegerValue location:point modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber context:nil eventNumber:1 clickCount:1 pressure:1];
        [NSApp postEvent:event atStart:NO];
    }
}
__attribute__((constructor)) static void install_player_event_test(void) {
    dispatch_async(dispatch_get_main_queue(),^{
        NSTimer *poll=[NSTimer timerWithTimeInterval:0.2 repeats:YES block:^(NSTimer *timer){
            for(NSWindow *window in NSApp.windows) {
                if(![window.title hasPrefix:@"QA Player"])continue;
                [timer invalidate];
                later(4,^{
                    [window makeKeyAndOrderFront:nil];
                    if([window.delegate respondsToSelector:@selector(windowDidBecomeKey:)]) [window.delegate windowDidBecomeKey:[NSNotification notificationWithName:NSWindowDidBecomeKeyNotification object:window]];
                    fprintf(stderr,"[QA] first responder=%s delegate=%s\n",NSStringFromClass(window.firstResponder.class).UTF8String,NSStringFromClass(window.delegate.class).UTF8String);
                    fprintf(stderr,"[QA] Cocoa queue target window=%ld bounds=%s flipped=%d\n",(long)window.windowNumber,NSStringFromRect(window.contentView.bounds).UTF8String,window.contentView.isFlipped);
                    click(window,225);
                    later(0.5,^{click(window,295);});
                    later(1.2,^{
                        NSString *word=NSProcessInfo.processInfo.environment[@"DROIDBRIDGE_QA_WORD"]?:@"CocoaInput";
                        for(NSNumber *kind in @[@(NSEventTypeKeyDown),@(NSEventTypeKeyUp)]) {
                            NSEvent *event=[NSEvent keyEventWithType:kind.unsignedIntegerValue location:NSZeroPoint modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber context:nil characters:word charactersIgnoringModifiers:word isARepeat:NO keyCode:0];
                            [NSApp postEvent:event atStart:NO];
                        }
                        id client=text_client(window.contentView);
                        if(!client && [window.firstResponder respondsToSelector:@selector(insertText:replacementRange:)])client=window.firstResponder;
                        if(client) {
                            [(id<NSTextInputClient>)client insertText:word replacementRange:NSMakeRange(NSNotFound,0)];
                            fprintf(stderr,"[QA] Public NSTextInputClient insertText called for %s\n",word.UTF8String);
                        }
                        fprintf(stderr,"[QA] Cocoa mouse and keyboard events posted for %s\n",word.UTF8String);
                    });
                });
                break;
            }
        }];
        [NSRunLoop.mainRunLoop addTimer:poll forMode:NSRunLoopCommonModes];
    });
}
