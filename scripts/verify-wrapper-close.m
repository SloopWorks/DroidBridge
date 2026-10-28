#import <AppKit/AppKit.h>
#include <stdlib.h>
// Test-only instrumentation in the QA wrapper process. Public window actions;
// all production lifecycle, termination, and backend code runs unchanged.
__attribute__((constructor)) static void install_wrapper_close_test(void) {
    unsetenv("DYLD_INSERT_LIBRARIES"); // Instrument only this host; leave all ADB/client children unchanged.
    dispatch_async(dispatch_get_main_queue(), ^{
        __block BOOL scheduled = NO;
        NSTimer *timer = [NSTimer timerWithTimeInterval:0.2 repeats:YES block:^(NSTimer *poll) {
            if (scheduled) return;
            for (NSWindow *window in NSApp.windows) {
                if (![window.title containsString:@" — DroidBridge"]) continue;
                scheduled = YES; [poll invalidate];
                NSTimer *closeTimer = [NSTimer timerWithTimeInterval:4 repeats:NO block:^(NSTimer *unused) {
                    (void)unused;
                    NSString *path = NSProcessInfo.processInfo.environment[@"DROIDBRIDGE_QA_WRAPPER_CLOSE_RECEIPT"];
                    [window.title writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
                    [window performClose:nil];
                }];
                [NSRunLoop.mainRunLoop addTimer:closeTimer forMode:NSRunLoopCommonModes];
                break;
            }
        }];
        [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
    });
}
