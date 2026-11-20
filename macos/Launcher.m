#import <AppKit/AppKit.h>

static NSString *label(NSString *en, NSString *zh) {
    return [[NSLocale preferredLanguages].firstObject hasPrefix:@"zh"] ? zh : en;
}

static NSAlert *alert(NSString *message) {
    NSAlert *result = [[NSAlert alloc] init];
    result.messageText = @"AGY Token Tips";
    result.informativeText = message;
    [NSApp activateIgnoringOtherApps:YES];
    return result;
}

static BOOL startedWithDebugging(NSRunningApplication *app) {
    // The dynamic port file is created by Electron, including on Desktop 2.32.
    NSString *portFile = [NSHomeDirectory() stringByAppendingPathComponent:
        @"Library/Application Support/Antigravity/DevToolsActivePort"];
    NSString *port = [NSString stringWithContentsOfFile:portFile encoding:NSUTF8StringEncoding error:NULL];
    if (port.integerValue > 0 && port.integerValue <= 65535) return YES;

    // Fixed-port launches (e.g. the previous 9222 launcher) need no port file.
    NSTask *ps = [[NSTask alloc] init];
    ps.executableURL = [NSURL fileURLWithPath:@"/bin/ps"];
    ps.arguments = @[@"-ww", @"-p", [@(app.processIdentifier) stringValue], @"-o", @"command="];
    NSPipe *output = [NSPipe pipe];
    ps.standardOutput = output;
    ps.standardError = [NSFileHandle fileHandleWithNullDevice];
    if (![ps launchAndReturnError:NULL]) return NO;
    NSData *data = [output.fileHandleForReading readDataToEndOfFile];
    [ps waitUntilExit];
    NSString *command = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return ps.terminationStatus == 0 && [command containsString:@" --remote-debugging-port="];
}

static int launch(NSString *targetID, NSString *defaultPath) {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    NSWorkspace *workspace = [NSWorkspace sharedWorkspace];
    NSRunningApplication *current = [NSRunningApplication runningApplicationsWithBundleIdentifier:targetID].firstObject;
    NSURL *url = current.bundleURL ?: [workspace URLForApplicationWithBundleIdentifier:targetID];
    if (!url) {
        NSURL *standard = [NSURL fileURLWithPath:defaultPath];
        if ([[NSBundle bundleWithURL:standard].bundleIdentifier isEqual:targetID]) url = standard;
    }
    if (!url) {
        [alert(label(@"Antigravity Desktop could not be found.", @"没有找到 Antigravity 客户端。")) runModal];
        return 1;
    }
    if (current && !current.terminated) {
        if (startedWithDebugging(current)) {
            [current activateWithOptions:NSApplicationActivateAllWindows];
            return 0;
        }
        NSAlert *choice = alert(label(
            @"Antigravity is already open without the metrics connection. Reopening it can interrupt active tasks. Save your work first.",
            @"当前 agy 尚未开启用量栏连接。重新打开会中断正在执行的任务，请先保存工作。"));
        [choice addButtonWithTitle:label(@"Keep working", @"继续当前工作")];
        [choice addButtonWithTitle:label(@"Quit and reopen", @"已保存，重新打开")];
        if ([choice runModal] != NSAlertSecondButtonReturn) return 0;
        if (![current terminate]) {
            [alert(label(@"Quit Antigravity with ⌘Q, then open AGY Token Tips again.",
                         @"请按 ⌘Q 退出 agy，再点一次 AGY Token Tips。")) runModal];
            return 1;
        }
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:25];
        while (!current.terminated && deadline.timeIntervalSinceNow > 0) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        }
        if (!current.terminated) {
            [alert(label(@"Antigravity is still open. Finish quitting it, then open AGY Token Tips again.",
                         @"agy 仍在运行。完成退出后，再点一次 AGY Token Tips。")) runModal];
            return 1;
        }
    }
    NSWorkspaceOpenConfiguration *config = [NSWorkspaceOpenConfiguration configuration];
    config.arguments = @[@"--remote-debugging-address=127.0.0.1", @"--remote-debugging-port=0"];
    __block BOOL completed = NO;
    __block NSError *launchError = nil;
    [workspace openApplicationAtURL:url configuration:config completionHandler:^(NSRunningApplication *app, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            launchError = error;
            completed = YES;
        });
    }];
    while (!completed) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    if (launchError) [alert(launchError.localizedDescription) runModal];
    return launchError ? 1 : 0;
}

int main(void) {
    @autoreleasepool { return launch(@"com.google.antigravity", @"/Applications/Antigravity.app"); }
}
