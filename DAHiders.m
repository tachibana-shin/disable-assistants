// DAHiders.m — hides the Siri / "Assistants" UI.
//
// Apple does not expose a public (or even a stable private) class name for the
// Assistants panel, and it changes between iOS releases. Instead of hardcoding
// one class, we walk the runtime class list once and hook every UIView /
// UIViewController class whose name refers to Siri or the assistant, plus a
// window-level safety net. Everything is gated by DAShouldHide().

#import "DATweak.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>

static NSMutableSet<NSString *> *gProcessedClasses = nil;
static NSUInteger gHookedClassCount = 0;
static NSTimeInterval gLastScanTime = 0;

#pragma mark - Hooking helpers

// The original IMP of every hooked method is stored as an NSValue attached to
// the class and keyed by the selector: a function pointer cannot be handed to
// objc_setAssociatedObject directly while ARC is enabled.
static NSValue *DAStoredOriginal(Class cls, SEL selector) {
    return objc_getAssociatedObject((id)cls, (const void *)selector);
}

// Returns the original implementation that MSHookMessageEx replaced.
IMP DAOriginalIMPForObject(id object, SEL selector) {
    Class cls = object_getClass(object);
    while (cls != Nil) {
        NSValue *stored = DAStoredOriginal(cls, selector);
        if (stored != nil) {
            return (IMP)stored.pointerValue;
        }
        cls = class_getSuperclass(cls);
    }
    return NULL;
}

// YES only when the class itself implements the selector (not a superclass).
static BOOL DAClassDeclaresSelector(Class cls, SEL selector) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    if (methods == NULL) {
        return NO;
    }
    BOOL found = NO;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == selector) {
            found = YES;
            break;
        }
    }
    free(methods);
    return found;
}

// Walks up the class chain and returns the class that implements the selector.
Class DAFindClassDeclaringSelector(Class cls, SEL selector) {
    while (cls != Nil && !DAClassDeclaresSelector(cls, selector)) {
        cls = class_getSuperclass(cls);
    }
    return cls;
}

BOOL DAHookMethodOnce(Class cls, SEL selector, IMP replacement) {
    if (cls == Nil || !DAClassDeclaresSelector(cls, selector)) {
        return NO;
    }
    if (DAStoredOriginal(cls, selector) != nil) {
        return YES;     // already hooked
    }
    IMP original = NULL;
    MSHookMessageEx(cls, selector, replacement, &original);
    if (original != NULL) {
        objc_setAssociatedObject((id)cls, (const void *)selector,
                                 [NSValue valueWithPointer:(const void *)original],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return YES;
    }
    return NO;
}

#pragma mark - Matching

static BOOL DANameLooksLikeAssistant(NSString *name) {
    if (name.length == 0) {
        return NO;
    }
    NSString *lower = name.lowercaseString;
    return [lower containsString:@"siri"] || [lower containsString:@"assistant"];
}

// Skip classes that only belong to the Settings app, the tweak must not break
// the place where the user configures it.
static BOOL DANameIsExcluded(NSString *lower) {
    return [lower containsString:@"setting"] || [lower containsString:@"preference"];
}

#pragma mark - Hiding

static void DAHideView(UIView *view) {
    if (view == nil) {
        return;
    }
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            DAHideView(view);
        });
        return;
    }
    [view setHidden:YES];
    [view setAlpha:0.0f];
    [view setUserInteractionEnabled:NO];
}

// The panel is usually hosted by a dedicated overlay window. Hiding only the
// content view would leave the white background behind, so hide the window too
// when it is clearly not the main application window.
static void DAHideObject(id object) {
    if (object == nil) {
        return;
    }
    if ([object isKindOfClass:[UIViewController class]]) {
        UIViewController *controller = (UIViewController *)object;
        DAHideView(controller.view);
        UIWindow *window = controller.view.window;
        BOOL assistantWindow = window != nil && DANameLooksLikeAssistant(NSStringFromClass(object_getClass(window)));
        BOOL overlayWindow = window != nil && window.windowLevel > UIWindowLevelNormal;
        if (window != nil && (assistantWindow || overlayWindow)) {
            DAHideView(window);
        }
        return;
    }
    if ([object isKindOfClass:[UIView class]]) {
        DAHideView((UIView *)object);
    }
}

static BOOL DAWindowLooksLikeAssistant(UIWindow *window) {
    if (DANameLooksLikeAssistant(NSStringFromClass(object_getClass(window)))) {
        return YES;
    }
    if (DANameLooksLikeAssistant(NSStringFromClass([window.rootViewController class]))) {
        return YES;
    }
    for (UIView *view in window.subviews) {
        if (DANameLooksLikeAssistant(NSStringFromClass(object_getClass(view)))) {
            return YES;
        }
        for (UIView *subview in view.subviews) {
            if (DANameLooksLikeAssistant(NSStringFromClass(object_getClass(subview)))) {
                return YES;
            }
        }
    }
    return NO;
}

#pragma mark - Hook bodies

static void DA_viewDidLoad(id self, SEL _cmd) {
    IMP original = DAOriginalIMPForObject(self, _cmd);
    if (original != NULL) {
        ((void (*)(id, SEL))original)(self, _cmd);
    }
    if (DAShouldHide()) {
        DAHideObject(self);
    }
}

static void DA_viewWillAppear(id self, SEL _cmd, BOOL animated) {
    IMP original = DAOriginalIMPForObject(self, _cmd);
    if (original != NULL) {
        ((void (*)(id, SEL, BOOL))original)(self, _cmd, animated);
    }
    if (DAShouldHide()) {
        DAHideObject(self);
    }
}

static void DA_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    IMP original = DAOriginalIMPForObject(self, _cmd);
    if (original != NULL) {
        ((void (*)(id, SEL, BOOL))original)(self, _cmd, animated);
    }
    if (DAShouldHide()) {
        DAHideObject(self);
    }
}

static void DA_didMoveToWindow(id self, SEL _cmd) {
    IMP original = DAOriginalIMPForObject(self, _cmd);
    if (original != NULL) {
        ((void (*)(id, SEL))original)(self, _cmd);
    }
    if (DAShouldHide()) {
        DAHideObject(self);
    }
}

static void DA_makeKeyAndVisible(id self, SEL _cmd) {
    if (DAShouldHide() && DANameLooksLikeAssistant(NSStringFromClass(object_getClass(self)))) {
        DAHideObject(self);   // never let the assistants window come up
        return;
    }
    IMP original = DAOriginalIMPForObject(self, _cmd);
    if (original != NULL) {
        ((void (*)(id, SEL))original)(self, _cmd);
    }
}

#pragma mark - Discovery

static void DAHookSiriClasses(void) {
    if (gProcessedClasses == nil) {
        gProcessedClasses = [NSMutableSet set];
    }

    @autoreleasepool {
        unsigned int classCount = 0;
        Class *classes = objc_copyClassList(&classCount);
        for (unsigned int i = 0; i < classCount; i++) {
            Class cls = classes[i];
            NSString *name = NSStringFromClass(cls);
            NSString *lower = name.lowercaseString;
            if (!DANameLooksLikeAssistant(lower) || DANameIsExcluded(lower)) {
                continue;
            }
            if ([gProcessedClasses containsObject:name]) {
                continue;
            }
            BOOL isView = [cls isSubclassOfClass:[UIView class]];
            BOOL isController = [cls isSubclassOfClass:[UIViewController class]];
            if (!isView && !isController) {
                continue;
            }
            [gProcessedClasses addObject:name];

            DAHookMethodOnce(cls, @selector(viewDidLoad), (IMP)DA_viewDidLoad);
            DAHookMethodOnce(cls, @selector(viewWillAppear:), (IMP)DA_viewWillAppear);
            DAHookMethodOnce(cls, @selector(viewDidAppear:), (IMP)DA_viewDidAppear);
            DAHookMethodOnce(cls, @selector(didMoveToWindow), (IMP)DA_didMoveToWindow);
            DAHookMethodOnce(cls, @selector(makeKeyAndVisible), (IMP)DA_makeKeyAndVisible);
            gHookedClassCount++;
            DALog(@"  hooked assistant class: %@", name);
        }
        free(classes);
    }
    gLastScanTime = [[NSDate date] timeIntervalSince1970];
    DALog(@"Class scan finished, assistant classes hooked: %lu",
          (unsigned long)gHookedClassCount);
}

#pragma mark - Entry points

void DAInstallHider(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Safety net for windows whose class is not named after Siri
        id token = [[NSNotificationCenter defaultCenter]
                    addObserverForName:UIWindowDidBecomeVisibleNotification
                                object:nil
                                 queue:[NSOperationQueue mainQueue]
                            usingBlock:^(NSNotification *note) {
            id object = note.object;
            if (![object isKindOfClass:[UIWindow class]] || !DAShouldHide()) {
                return;
            }
            UIWindow *window = (UIWindow *)object;
            if (DAWindowLooksLikeAssistant(window)) {
                DAHideView(window);
            }
            // Lazily loaded frameworks: pick up new classes on the way.
            NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
            if (now - gLastScanTime > 30.0) {
                DAHookSiriClasses();
            }
        }];
        (void)token;

        DAHookSiriClasses();
        for (NSInteger delay = 3; delay <= 12; delay += 3) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                DAHookSiriClasses();
            });
        }
        DALog(@"Hider installed, hiding=%d", DAShouldHide());
    });
}

void DAApplyHiderNow(void) {
    if (!DAShouldHide()) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        DAHookSiriClasses();
        for (UIWindow *window in [UIApplication sharedApplication].windows) {
            if (DAWindowLooksLikeAssistant(window)) {
                DAHideView(window);
            }
        }
        DALog(@"Re-applied hiding after a preference change");
    });
}
