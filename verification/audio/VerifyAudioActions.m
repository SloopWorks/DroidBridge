#import <AppKit/AppKit.h>
// Public-AppKit-only exercise of the test injector. No DroidBridge controller,
// device transport, persistent preferences, clipboard or real audio is used.
@interface Fixture : NSObject <NSApplicationDelegate,NSMenuDelegate>
@property NSWindow *window;
@property NSPopUpButton *route;
@property NSTextField *status;
@property NSMenu *audio;
@property NSString *selected;
@property NSInteger retries;
@end
@implementation Fixture
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
 (void)notification;self.selected=@"mac";
 self.window=[[NSWindow alloc] initWithContentRect:NSMakeRect(100,100,500,300) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];self.window.title=@"DroidBridge";
 self.route=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(10,10,200,30) pullsDown:NO];self.route.accessibilityLabel=@"Device audio route";self.route.autoenablesItems=NO;
 for(NSString *raw in @[@"mac",@"phone",@"macAndPhone"]){[self.route addItemWithTitle:raw];self.route.lastItem.representedObject=raw;}
 self.route.target=self;self.route.action=@selector(change:);[self.window.contentView addSubview:self.route];
 self.status=[NSTextField labelWithString:@"Mac fixture ready"];self.status.frame=NSMakeRect(10,60,480,30);self.status.accessibilityLabel=@"Device audio status";[self.window.contentView addSubview:self.status];
 NSMenu *main=[NSMenu new];NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:@"Audio" action:nil keyEquivalent:@""];self.audio=[[NSMenu alloc] initWithTitle:@"Audio"];self.audio.autoenablesItems=NO;self.audio.delegate=self;item.submenu=self.audio;[main addItem:item];NSApp.mainMenu=main;
 // Deliberately leave the fixture launcher hidden, like a native app wrapper.
}
- (void)change:(id)sender {self.selected=[sender isKindOfClass:NSPopUpButton.class]?((NSPopUpButton *)sender).selectedItem.representedObject:((NSMenuItem *)sender).representedObject;[self.route selectItemAtIndex:[@[@"mac",@"phone",@"macAndPhone"] indexOfObject:self.selected]];self.status.stringValue=[@"Selected " stringByAppendingString:self.selected];}
- (void)retry:(id)sender {(void)sender;self.retries++;self.status.stringValue=[NSString stringWithFormat:@"Retry %ld",(long)self.retries];}
- (void)menuNeedsUpdate:(NSMenu *)menu {
 [menu removeAllItems];for(NSString *raw in @[@"mac",@"phone",@"macAndPhone"]){NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:raw action:@selector(change:) keyEquivalent:@""];item.target=self;item.representedObject=raw;item.state=[raw isEqual:self.selected]?NSControlStateValueOn:NSControlStateValueOff;[menu addItem:item];}
 NSMenuItem *retry=[[NSMenuItem alloc] initWithTitle:@"Retry Audio" action:@selector(retry:) keyEquivalent:@""];retry.target=self;[menu addItem:retry];
}
@end
int main(void){@autoreleasepool{NSApplication *app=NSApplication.sharedApplication;[app setActivationPolicy:NSApplicationActivationPolicyRegular];Fixture *delegate=[Fixture new];app.delegate=delegate;[app run];(void)delegate;return 0;}}
