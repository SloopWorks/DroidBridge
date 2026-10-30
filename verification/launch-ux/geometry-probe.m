/* TEST ONLY. Observe public SDL/AppKit/CoreGraphics geometry inside the exact
 * Player process. No screen image capture or Android input is performed. */
#import <AppKit/AppKit.h>
#include <SDL3/SDL.h>
#include <unistd.h>

__attribute__((constructor)) static void isolate(void) { unsetenv("DYLD_INSERT_LIBRARIES"); }
static void inspect_geometry(void) {
    static Uint64 last;
    if (SDL_GetTicks() - last < 500) return;
    last = SDL_GetTicks();
    int count=0;SDL_Window **windows=SDL_GetWindows(&count);
    for (int i=0;i<count;i++) {
        SDL_Window *w=windows[i];int x=0,y=0,width=0,height=0,pw=0,ph=0,top=0,left=0,bottom=0,right=0;
        SDL_GetWindowPosition(w,&x,&y);SDL_GetWindowSize(w,&width,&height);SDL_GetWindowSizeInPixels(w,&pw,&ph);SDL_GetWindowBordersSize(w,&top,&left,&bottom,&right);
        NSWindow *n=(__bridge NSWindow *)SDL_GetPointerProperty(SDL_GetWindowProperties(w),SDL_PROP_WINDOW_COCOA_WINDOW_POINTER,NULL);
        NSMutableArray *cg=[NSMutableArray array];
        NSArray *rows=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll,kCGNullWindowID));
        for (NSDictionary *row in rows) if ([row[(id)kCGWindowOwnerPID] intValue]==getpid() && [row[(id)kCGWindowLayer] intValue]==0)
            [cg addObject:@{@"number":row[(id)kCGWindowNumber],@"bounds":row[(id)kCGWindowBounds],@"onscreen":row[(id)kCGWindowIsOnscreen] ?: @NO}];
        NSDictionary *receipt=@{@"pid":@(getpid()),@"SDL_position":@[@(x),@(y)],@"SDL_size":@[@(width),@(height)],@"SDL_pixels":@[@(pw),@(ph)],@"SDL_borders":@[@(top),@(left),@(bottom),@(right)],@"NSWindow_frame":NSStringFromRect(n.frame),@"NSWindow_content":NSStringFromRect([n contentRectForFrameRect:n.frame]),@"NSView_bounds":NSStringFromRect(n.contentView.bounds),@"NSWindow_number":@(n.windowNumber),@"NSWindow_visible":@(n.visible),@"CG_windows":cg};
        NSData *data=[NSJSONSerialization dataWithJSONObject:receipt options:NSJSONWritingSortedKeys error:NULL];
        fprintf(stderr,"GEOMETRY_PROBE %s\n",[[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] UTF8String]);
    }
    SDL_free(windows);
}
static bool geometry_wait(SDL_Event *event) {
    inspect_geometry();
    while (!SDL_WaitEventTimeout(event,50)) inspect_geometry();
    inspect_geometry();return true;
}
__attribute__((used)) static struct {const void *replacement;const void *original;} hook
__attribute__((section("__DATA,__interpose")))={(const void *)&geometry_wait,(const void *)&SDL_WaitEvent};
