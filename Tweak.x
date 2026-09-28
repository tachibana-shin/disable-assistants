// Tweak.x — entry point.
//
// Two kinds of process are handled:
//   * SpringBoard (and the assistant service): install the hider.
//   * Settings (com.apple.Preferences): keep the two live rows of the
//     PreferenceLoader panel up to date and run the respring action.

#import "DATweak.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <notify.h>
#import <unistd.h>

// The IMP returned by MSHookMessageEx has to be re-cast to the real selector
// signature. Newer compilers warn about it and Theos builds with -Werror.
#if __has_warning("-Wcast-function-type-mismatch")
#pragma clang diagnostic ignored "-Wcast-function-type-mismatch"
#endif

static NSString *const kSettingsBundleID = @"com.apple.Preferences";

static BOOL gSettingsHooksInstalled = NO;
static id gActiveObserver = nil;
static dispatch_source_t gPrefsSource = nil;

static const char kTapRecognizerKey = 0;

#pragma mark - Settings panel helpers

static UIViewController *DATopViewController(void) {
    UIWindow *keyWindow = nil;
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        if (window.isKeyWindow) {
            keyWindow = window;
            break;
        }
    }
    if (keyWindow == nil) {
        keyWindow = [UIApplication sharedApplication].windows.lastObject;
    }
    UIViewController *controller = keyWindow.rootViewController;
    while (controller.presentedViewController != nil) {
        controller = controller.presentedViewController;
    }
    return controller;
}

static void DARespring(void) {
    pid_t pid = fork();
    if (pid == 0) {
        const char *rootless[] = {"/var/jb/usr/bin/killall", "-9", "SpringBoard", NULL};
        execv(rootless[0], (char *const *)rootless);
        const char *rootful[] = {"/usr/bin/killall", "-9", "SpringBoard", NULL};
        execv(rootful[0], (char *const *)rootful);
        _exit(0);
    }
}

static void DANotifyPrefsChanged(void) {
    notify_post(DA_NOTIFY_PREFS_CHANGED);
}

static BOOL DAHasTapRecognizer(UITableViewCell *cell) {
    return objc_getAssociatedObject((id)cell, &kTapRecognizerKey) != NULL;
}

// Target of the tap recognisers attached to the special rows.
@interface DASettingsActions : NSObject
+ (instancetype)shared;
- (void)handleTap:(UITapGestureRecognizer *)recognizer;
@end

@implementation DASettingsActions

+ (instancetype)shared {
    static DASettingsActions *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[DASettingsActions alloc] init];
    });
    return shared;
}

- (void)handleTap:(UITapGestureRecognizer *)recognizer {
    UITableViewCell *cell = (UITableViewCell *)recognizer.view;
    NSString *text = cell.textLabel.text ?: @"";

    if ([cell.superview isKindOfClass:[UITableView class]]) {
        UITableView *table = (UITableView *)cell.superview;
        NSIndexPath *indexPath = [table indexPathForCell:cell];
        if (indexPath != nil) {
            [table deselectRowAtIndexPath:indexPath animated:YES];
        }
    }

    if ([text hasPrefix:DA_STATUS_PREFIX]) {
        DAReloadPrefsIfNeeded();
        UIViewController *presenter = DATopViewController();
        if (presenter == nil) {
            return;
        }
        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:@"Disable Assistants"
                                                message:DAStatusReportText()
                                         preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [presenter presentViewController:alert animated:YES completion:nil];
        return;
    }

    if ([text hasPrefix:DA_RESPRING_PREFIX]) {
        DARespring();
    }
}

@end

#pragma mark - Live rows

// YES when the row is one of the two special rows, and reports which.
static BOOL DARowKind(UITableViewCell *cell, NSString **outKind) {
    if (![cell isKindOfClass:[UITableViewCell class]]) {
        return NO;
    }
    NSString *text = cell.textLabel.text ?: @"";
    if ([text hasPrefix:DA_STATUS_PREFIX]) {
        if (outKind != NULL) { *outKind = DA_STATUS_PREFIX; }
        return YES;
    }
    if ([text hasPrefix:DA_RESPRING_PREFIX]) {
        if (outKind != NULL) { *outKind = DA_RESPRING_PREFIX; }
        return YES;
    }
    return NO;
}

static void DAUpdateRow(UITableViewCell *cell, NSString *kind) {
    if ([kind isEqualToString:DA_STATUS_PREFIX]) {
        DAReloadPrefsIfNeeded();
        cell.textLabel.text = DAStatusShortText();
    }
    if (!DAHasTapRecognizer(cell)) {
        UITapGestureRecognizer *tap =
            [[UITapGestureRecognizer alloc] initWithTarget:[DASettingsActions shared]
                                                    action:@selector(handleTap:)];
        tap.delaysTouchesBegan = NO;
        tap.cancelsTouchesInView = NO;
        [cell addGestureRecognizer:tap];
        objc_setAssociatedObject((id)cell, &kTapRecognizerKey, tap, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void DAUpdateRowsInTable(UITableView *table) {
    static BOOL updating = NO;
    if (updating) {
        return;     // guard against re-entering through layout invalidation
    }
    updating = YES;
    for (UITableViewCell *cell in table.visibleCells) {
        NSString *kind = nil;
        if (DARowKind(cell, &kind)) {
            DAUpdateRow(cell, kind);
        }
    }
    updating = NO;
}

#pragma mark - Hook bodies (Settings process)

static void DA_layoutSubviews(id self, SEL _cmd) {
    IMP original = DAOriginalIMPForObject(self, _cmd);
    if (original != NULL) {
        ((void (*)(id, SEL))original)(self, _cmd);
    }
    if ([self isKindOfClass:[UITableView class]] && [self window] != nil) {
        DAUpdateRowsInTable((UITableView *)self);
    }
}

static void DA_reloadData(id self, SEL _cmd) {
    IMP original = DAOriginalIMPForObject(self, _cmd);
    if (original != NULL) {
        ((void (*)(id, SEL))original)(self, _cmd);
    }
    if ([self isKindOfClass:[UITableView class]]) {
        DAUpdateRowsInTable((UITableView *)self);
    }
}

static void DA_switchSetOn(id self, SEL _cmd, BOOL on, BOOL animated) {
    IMP original = DAOriginalIMPForObject(self, _cmd);
    if (original != NULL) {
        ((void (*)(id, SEL, BOOL, BOOL))original)(self, _cmd, on, animated);
    }
    DANotifyPrefsChanged();
}

static BOOL DATryInstallSettingsHooks(void) {
    if (gSettingsHooksInstalled) {
        return YES;
    }
    Class tableViewClass = NSClassFromString(@"UITableView");
    Class switchClass = NSClassFromString(@"UISwitch");
    if (tableViewClass == Nil || switchClass == Nil) {
        return NO;
    }

    // PreferenceLoader's list controller overrides the UITableView data source,
    // so the table view itself is the reliable hook point.
    BOOL hooked = NO;
    Class layoutClass = DAFindClassDeclaringSelector(tableViewClass, @selector(layoutSubviews));
    if (layoutClass != Nil) {
        hooked = DAHookMethodOnce(layoutClass, @selector(layoutSubviews), (IMP)DA_layoutSubviews) || hooked;
    }
    Class reloadClass = DAFindClassDeclaringSelector(tableViewClass, @selector(reloadData));
    if (reloadClass != Nil) {
        hooked = DAHookMethodOnce(reloadClass, @selector(reloadData), (IMP)DA_reloadData) || hooked;
    }
    DAHookMethodOnce(switchClass, @selector(setOn:animated:), (IMP)DA_switchSetOn);

    gSettingsHooksInstalled = hooked;
    return hooked;
}

#pragma mark - Preference change notifications

static void DARegisterPrefsObserver(void) {
    int token = 0;
    if (notify_register_check(DA_NOTIFY_PREFS_CHANGED, &token) != NOTIFY_STATUS_OK) {
        return;
    }
    dispatch_queue_t queue = dispatch_queue_create("shin.disableassistants.prefs", DISPATCH_QUEUE_SERIAL);
    gPrefsSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_DATA_PASSIVE, 0, 0, queue);
    dispatch_source_set_event_handler(gPrefsSource, ^{
        DAReloadPrefsIfNeeded();
        DAApplyHiderNow();
    });
    dispatch_resume(gPrefsSource);
}

#pragma mark - Constructor

%ctor {
    @autoreleasepool {
        DAReloadPrefs();
        NSString *bundleID = [NSBundle mainBundle].bundleIdentifier ?: @"";

        if ([bundleID isEqualToString:kSettingsBundleID]) {
            if (!DATryInstallSettingsHooks()) {
                gActiveObserver =
                    [[NSNotificationCenter defaultCenter]
                     addObserverForName:UIApplicationDidBecomeActiveNotification
                                 object:nil
                                  queue:[NSOperationQueue mainQueue]
                             usingBlock:^(NSNotification *note) {
                        DATryInstallSettingsHooks();
                    }];
            }
            DALog(@"Settings panel hooks installed: %d", gSettingsHooksInstalled);
        } else {
            DAInstallHider();
        }

        DARegisterPrefsObserver();
    }
}
