#import <AppKit/AppKit.h>
#import <sys/stat.h>
#import <unistd.h>

// Test-only lower bound: no DroidBridge modules, ADB, broker or product prefs.
@interface BaselineDelegate : NSObject <NSApplicationDelegate>
@property(strong) NSWindow *window;
@property(strong) NSMutableDictionary *phases;
@property(strong) NSString *output;
@end
@implementation BaselineDelegate
- (void)record:(NSString *)name {
    self.phases[name] = @(NSProcessInfo.processInfo.systemUptime);
}
- (void)flush {
    [[NSJSONSerialization dataWithJSONObject:self.phases options:NSJSONWritingPrettyPrinted error:NULL] writeToFile:self.output atomically:YES];
}
- (void)applicationWillFinishLaunching:(NSNotification *)notification {
    [self record:@"will_finish_launching"];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(240, 180, 480, 720)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"DroidBridge AppKit Baseline";
    self.window.restorable = NO;
    NSTextField *label = [NSTextField labelWithString:@"Loading Android application…"];
    label.frame = NSMakeRect(24, 350, 400, 24);
    [self.window.contentView addSubview:label];
    [self record:@"window_constructed"];
    [self.window makeKeyAndOrderFront:nil];
    [self record:@"window_ordered"];
    [self flush];
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [self record:@"did_finish_launching"];
    [self flush];
    [NSApp activateIgnoringOtherApps:YES];
    [NSTimer scheduledTimerWithTimeInterval:2 repeats:NO block:^(NSTimer *timer) { [NSApp terminate:nil]; }];
}
@end
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3) return 64;
        NSString *root = [NSString stringWithUTF8String:argv[1]], *output = [NSString stringWithUTF8String:argv[2]];
        struct stat metadata;
        if (lstat(root.fileSystemRepresentation, &metadata) || !S_ISDIR(metadata.st_mode) || metadata.st_uid != getuid() || (metadata.st_mode & 0777) != 0700 || ![root isEqual:root.stringByResolvingSymlinksInPath] || ![output.stringByDeletingLastPathComponent isEqual:root] || ![output.lastPathComponent isEqual:@"phases.json"]) return 65;
        umask(0077);
        NSMutableDictionary *phases = [@{@"app_entry": @(NSProcessInfo.processInfo.systemUptime), @"pid": @(getpid())} mutableCopy];
        NSApplication *app = NSApplication.sharedApplication;
        phases[@"appkit_shared_ready"] = @(NSProcessInfo.processInfo.systemUptime);
        BaselineDelegate *delegate = [BaselineDelegate new];
        delegate.phases = phases; delegate.output = output;
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
