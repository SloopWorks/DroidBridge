#import <AppKit/AppKit.h>
#include <stdlib.h>

// Passive, test-only observer. Public NSWindow visibility and accessibility
// labels only: no input injection, private Swift storage or screen capture.
static NSArray<NSView *> *views(NSView *view) {
    if (!view) return @[];
    NSMutableArray *result = [NSMutableArray arrayWithObject:view];
    for (NSView *child in view.subviews) [result addObjectsFromArray:views(child)];
    return result;
}
__attribute__((constructor)) static void observe(void) {
    NSTimeInterval began = NSProcessInfo.processInfo.systemUptime;
    NSString *path = NSProcessInfo.processInfo.environment[@"DROIDBRIDGE_PREVIEW_OBSERVATIONS"];
    NSString *expected = NSProcessInfo.processInfo.environment[@"DROIDBRIDGE_PREVIEW_TITLE"];
    unsetenv("DYLD_INSERT_LIBRARIES");
    if (!path.length || !expected.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        __block NSNumber *visible = nil;
        __block NSNumber *video = nil;
        NSTimer *timer = [NSTimer timerWithTimeInterval:.01 repeats:YES block:^(NSTimer *timer) {
            for (NSWindow *window in NSApp.windows) {
                if (![window.title isEqual:expected] || !window.visible) continue;
                BOOL changed = NO;
                if (!visible) { visible = @(NSProcessInfo.processInfo.systemUptime); changed = YES; }
                for (NSView *view in views(window.contentView)) {
                    if (!video && [NSStringFromClass(view.class) containsString:@"AndroidVideoView"] && [view.accessibilityLabel isEqual:expected]) {
                        video = @(NSProcessInfo.processInfo.systemUptime); changed = YES;
                    }
                }
                if (changed) {
                    NSDictionary *result = @{@"constructor_uptime": @(began), @"first_visible_window_uptime": visible,
                        @"first_presented_video_uptime": video ?: NSNull.null, @"pid": @(getpid()),
                        @"window_number": @(window.windowNumber), @"scope": @"Public NSWindow visibility and native video accessibility label; no WindowServer paint or physical-focus claim"};
                    [[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:NULL] writeToFile:path atomically:YES];
                }
                if (video) [timer invalidate];
                return;
            }
        }];
        [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
        [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSModalPanelRunLoopMode];
    });
}
