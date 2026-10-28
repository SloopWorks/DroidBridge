#import <AppKit/AppKit.h>
#include <stdlib.h>
static NSArray<NSView *> *descendants(NSView *root) {
    if(!root)return @[];
    NSMutableArray *all=[NSMutableArray arrayWithObject:root];
    for(NSView *child in root.subviews) [all addObjectsFromArray:descendants(child)];
    return all;
}
__attribute__((constructor)) static void run_qa_actions(void) {
    unsetenv("DYLD_INSERT_LIBRARIES");
    dispatch_async(dispatch_get_main_queue(), ^{
        __block NSInteger phase=0;__block double started=CFAbsoluteTimeGetCurrent();__block double launchStarted=0;
        __block NSButton *add=nil,*cancel=nil,*decor=nil,*launch=nil;
        __block NSPopUpButton *backend=nil;__block NSTableView *table=nil;__block NSTextField *progress=nil;
        NSString *mode=NSProcessInfo.processInfo.environment[@"DROIDBRIDGE_QA_UI_MODE"] ?: @"add";
        NSString *path=NSProcessInfo.processInfo.environment[@"DROIDBRIDGE_QA_UI_RECEIPT"];
        void (^finish)(BOOL,NSString *)=^(BOOL pass,NSString *message) {
            NSDictionary *value=@{@"passed":@(pass),@"mode":mode,@"message":message?:@"",@"progress":progress.stringValue?:@"",@"rows":@(table.numberOfRows),@"elapsed_seconds":@(CFAbsoluteTimeGetCurrent()-started),@"instrumentation":@"public AppKit performClick; physical OS click/focus unverified"};
            NSData *data=[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingPrettyPrinted error:NULL];[data writeToFile:path atomically:YES];
            [NSApp terminate:nil];
        };
        NSTimer *timer=[NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *tick) {
            if(CFAbsoluteTimeGetCurrent()-started>120){[tick invalidate];finish(NO,@"Timed out waiting for installed launcher control workflow");return;}
            if(phase==0){
                for(NSWindow *window in NSApp.windows){
                    for(NSView *view in descendants(window.contentView)){
                        if([view isKindOfClass:NSButton.class]){
                            NSButton *b=(NSButton*)view;
                            if([b.title isEqual:@"Add All Device Apps to Spotlight"])add=b;
                            if([b.title isEqual:@"Cancel"])cancel=b;
                            if([b.title isEqual:@"Show Android system decorations"])decor=b;
                            if([b.title isEqual:@"Launch App"])launch=b;
                        }
                        if([view isKindOfClass:NSPopUpButton.class]&&[((NSPopUpButton*)view).itemTitles containsObject:@"scrcpy fallback"]) backend=(NSPopUpButton*)view;
                        if([view isKindOfClass:NSTableView.class]&&[[(NSTableView*)view tableColumnWithIdentifier:@"package"] isKindOfClass:NSTableColumn.class])table=(NSTableView*)view;
                        if([view isKindOfClass:NSTextField.class]&&[((NSTextField*)view).stringValue containsString:@"Ready to add all"])progress=(NSTextField*)view;
                    }
                }
                if(!add||!progress||!table||table.numberOfRows<3||!add.enabled)return;
                if([mode isEqual:@"cancel"]){[backend selectItemAtIndex:1];}
                if(!add.target||!add.action||![add.target respondsToSelector:add.action]){[tick invalidate];finish(NO,@"AddAll has no working target/action");return;}
                [add performClick:nil];phase=1;return;
            }
            if(phase==1){
                if([mode isEqual:@"cancel"]){
                    NSRegularExpression *re=[NSRegularExpression regularExpressionWithPattern:@"^[1-9][0-9]*/" options:0 error:NULL];
                    BOOL completed=[re firstMatchInString:progress.stringValue options:0 range:NSMakeRange(0,progress.stringValue.length)]!=nil;
                    if(cancel.enabled&&completed&&[progress.stringValue containsString:@"Working:"]){[cancel performClick:nil];phase=2;}
                    else if(add.enabled&&[progress.stringValue containsString:@"Finished."]){[tick invalidate];finish(NO,@"Cohort completed before cancellation boundary");}
                }else if(add.enabled&&[progress.stringValue containsString:@"Finished."]){
                    if(![progress.stringValue containsString:@"0 errors."]){[tick invalidate];finish(NO,@"Installed AddAll reported per-app errors");return;}
                    // Actual preference target/action, then actual launcher button.
                    if(decor.state!=NSControlStateValueOff)[decor performClick:nil];
                    NSInteger selected=-1;
                    for(NSInteger row=0;row<table.numberOfRows;row++){
                        NSView *cell=[table viewAtColumn:1 row:row makeIfNecessary:YES];
                        for(NSView *item in descendants(cell))if([item isKindOfClass:NSTextField.class]&&[((NSTextField*)item).stringValue isEqual:@"com.android.settings"])selected=row;
                    }
                    if(selected<0){[tick invalidate];finish(NO,@"Settings package not selectable in installed launcher");return;}
                    [table selectRowIndexes:[NSIndexSet indexSetWithIndex:selected] byExtendingSelection:NO];
                    [launch performClick:nil];phase=3;launchStarted=CFAbsoluteTimeGetCurrent();
                }
                return;
            }
            if(phase==2&&add.enabled&&!cancel.enabled&&[progress.stringValue containsString:@"Cancelled."]){[tick invalidate];finish(YES,@"Actual Cancel action completed; accepted history retained");return;}
            if(phase==3&&CFAbsoluteTimeGetCurrent()-launchStarted>5){[tick invalidate];finish(YES,@"Actual AddAll, decoration preference and LaunchApp actions completed");}
        }];
        [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
    });
}
