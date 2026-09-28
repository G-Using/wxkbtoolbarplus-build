// WXKeyboardToolbarPlus
// Theos + Logos tweak for WeType (微信输入法 / wxkb).
//
// ===========================================================================
// GROUND TRUTH (from the on-device binary dump, not guesses)
// ===========================================================================
//   App          : /var/containers/Bundle/Application/<UUID>/wxkb.app
//                  bundle = com.tencent.wetype            exec = wxkb
//   Keyboard ext : wxkb.app/PlugIns/wxkb_plugin.appex
//                  bundle = com.tencent.wetype.keyboard   exec = wxkb_plugin
//
//   Real classes : WBFunctionToolBar, WBCustomToolBarView, WBCustomToolBarScrolView,
//                  WBToolBarButton, WBCombinedToolBarButton, WBTranslateViewToolBar,
//                  WBToolBarAuxiliary, WBCCFuncItem, WBCoreStackView, WBPlusSelectionView
//   Protocols    : WBCustomToolBarEditingProtocol, WBCustomToolBarScrolViewDelegate
//
//   NOTE: the class "WXKeyboardToolbarView" DOES NOT EXIST. All early builds
//   hooked a nonexistent class and therefore did nothing at all.
//
// ===========================================================================
// WHY v0.2.0 CRASHED THE APP  (wxkb-2026-09-28-224927.ips)
// ===========================================================================
//   exception : EXC_CRASH / SIGKILL
//   termination: FRONTBOARD 0x8BADF00D "process-launch watchdog transgression"
//                "exhausted real (wall clock) time allowance of 20.00 seconds"
//   "Elapsed total CPU time (seconds): 33.850"
//   main thread : dispatch_once_wait  <- waits on _UIApplicationConfigurationLoader
//   other thread: dlopen_from -> _os_unfair_lock_lock_slow   <- blocked on dyld
//
//   A tweak's %ctor runs INSIDE dyld's dlopen(), i.e. while the dyld global
//   loader lock is held. v0.2.0 did four full passes over every loaded class
//   (~40k classes, class_copyMethodList each) plus a dump that built an
//   NSString per selector per class (millions of allocations) right there.
//   That held the dyld lock for >20s, so every other thread's dlopen blocked
//   forever, the launch never completed, and the watchdog killed the process.
//
//   => HARD RULE FOR THIS FILE: %ctor must do *nothing* but spawn one thread.
//      All real work happens later, off the launch path, on that thread.
//
// ===========================================================================
// HARD RULES
// ===========================================================================
//   - Never recreate buttons. Existing UIControls are only reparented into a
//     UIScrollView with their frames preserved, so icons, target/action chains
//     and hit testing stay byte-identical to the originals.
//   - Never swizzle global UIKit methods. A class is only hooked when it
//     *itself* implements -layoutSubviews (checked at runtime), so we can never
//     end up replacing -[UIView layoutSubviews] and breaking every other tweak
//     (liquid glass keyboard beautifiers included).
//   - Never do heavy work on the launch path (see above).
//   - Prefs are read from the PreferenceLoader domain, NOT from
//     +standardUserDefaults (which inside the app/extension would read that
//     app's own defaults and never match our keys — a bug in v0.2.0).

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <pthread.h>
#import <dispatch/dispatch.h>
#import <unistd.h>
#import <string.h>
#import <stdlib.h>

#pragma mark - Preference keys

static NSString * const kPrefDomain       = @"com.gusing.wxkbtoolbarplus";
static NSString * const kPrefEnabled      = @"Enabled";          // BOOL master
static NSString * const kPrefHidePanel    = @"HidePanel";        // BOOL collapse arrow
static NSString * const kPrefHideVoice    = @"HideVoice";        // BOOL mic
static NSString * const kPrefHideEmoji    = @"HideEmoji";        // BOOL emoji
static NSString * const kPrefHideAI       = @"HideAI";           // BOOL AI input
static NSString * const kPrefHideSimplify = @"HideSimplify";     // BOOL
static NSString * const kPrefHideKeyboard = @"HideKeyboard";     // BOOL
static NSString * const kPrefForceUncap   = @"ForceUncap";       // BOOL lift the 7 cap

#pragma mark - Small C helpers (no allocation, safe on hot paths)

// Case-insensitive substring test that does not depend on strcasestr().
static BOOL WXKBT_NameHas(const char *name, const char *needle) {
    if (name == NULL || needle == NULL) return NO;
    size_t nl = strlen(needle);
    if (nl == 0) return NO;
    for (const char *p = name; *p != '\0'; p++) {
        size_t i = 0;
        while (i < nl && p[i] != '\0') {
            char a = p[i], b = needle[i];
            if (a >= 'A' && a <= 'Z') a = (char)(a + 32);
            if (b >= 'A' && b <= 'Z') b = (char)(b + 32);
            if (a != b) break;
            i++;
        }
        if (i == nl) return YES;
    }
    return NO;
}

static BOOL WXKBT_ClassIsSubclassOf(Class cls, const char *superName) {
    if (cls == Nil || superName == NULL) return NO;
    Class sup = objc_getClass(superName);
    if (sup == Nil) return NO;
    Class w = cls;
    while (w != Nil) {
        if (w == sup) return YES;
        w = class_getSuperclass(w);
    }
    return NO;
}

// YES when `cls` itself defines -sel (not merely inherits it from an ancestor).
// This is what keeps us from ever replacing a UIKit implementation.
static BOOL WXKBT_OwnsSelector(Class cls, SEL sel) {
    if (cls == Nil || sel == NULL) return NO;
    Method m = class_getInstanceMethod(cls, sel);
    if (m == NULL) return NO;
    Class sup = class_getSuperclass(cls);
    if (sup == Nil) return YES;
    Method sm = class_getInstanceMethod(sup, sel);
    if (sm == NULL) return YES;
    return method_getImplementation(m) != method_getImplementation(sm);
}

#pragma mark - Preferences

static NSUserDefaults *WXKBT_Prefs(void) {
    static NSUserDefaults *defs = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        defs = [[NSUserDefaults alloc] initWithSuiteName:kPrefDomain];
        if (defs == nil) defs = [NSUserDefaults standardUserDefaults];
    });
    return defs;
}

// Master switch. Absent key => ON, so the tweak works out of the box while
// still giving the user a one-tap kill switch in Settings.
static BOOL WXKBT_MasterEnabled(void) {
    NSUserDefaults *d = WXKBT_Prefs();
    if (d == nil) return YES;
    if ([d objectForKey:kPrefEnabled] == nil) return YES;
    return [d boolForKey:kPrefEnabled];
}

static BOOL WXKBT_ForceUncapEnabled(void) {
    NSUserDefaults *d = WXKBT_Prefs();
    if (d == nil) return YES;
    if ([d objectForKey:kPrefForceUncap] == nil) return YES;
    return [d boolForKey:kPrefForceUncap];
}

#pragma mark - Diagnostics (sandbox-only, small, never on the launch path)

static BOOL WXKBT_WriteStatus(NSString *basename, NSString *body) {
    NSString *home = NSHomeDirectory();
    if (home.length == 0) return NO;
    NSArray<NSString *> *dirs = @[
        [home stringByAppendingPathComponent:@"Documents"],
        home,
    ];
    BOOL any = NO;
    for (NSString *dir in dirs) {
        BOOL isDir = NO;
        if (![[NSFileManager defaultManager] fileExistsAtPath:dir isDirectory:&isDir] || !isDir) {
            continue;
        }
        NSString *path = [dir stringByAppendingPathComponent:basename];
        if ([body writeToFile:path atomically:YES
                     encoding:NSUTF8StringEncoding error:NULL]) {
            any = YES;
        }
    }
    return any;
}

#pragma mark - Button identification + visibility

static NSString *WXKBT_IdentForButton(UIView *btn) {
    NSString *acc = btn.accessibilityIdentifier;
    if (acc.length > 0) return acc;
    NSString *label = btn.accessibilityLabel;
    if (label.length > 0) return label;
    const char *cn = class_getName([btn class]);
    NSString *clsName = (cn != NULL) ? [NSString stringWithUTF8String:cn] : @"Button";
    if (btn.tag != 0) {
        return [NSString stringWithFormat:@"%@_%ld", clsName, (long)btn.tag];
    }
    return clsName;
}

static BOOL WXKBT_MatchesKeyword(NSString *ident, NSArray<NSString *> *keywords) {
    if (ident.length == 0) return NO;
    for (NSString *kw in keywords) {
        if (kw.length == 0) continue;
        if ([ident rangeOfString:kw options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

static NSDictionary<NSString *, NSArray<NSString *> *> *WXKBT_KeywordMap(void) {
    return @{
        kPrefHidePanel:    @[@"panel", @"chevron", @"arrow", @"expand", @"close", @"hide", @"shrink"],
        kPrefHideVoice:    @[@"voice", @"mic", @"audio", @"speak", @"dictation"],
        kPrefHideEmoji:    @[@"emoji", @"sticker", @"face", @"expression"],
        kPrefHideAI:       @[@"ai", @"smart", @"assistant", @"wenan"],
        kPrefHideSimplify: @[@"simplif", @"tradition", @"chinese"],
        kPrefHideKeyboard: @[@"globe", @"keyboard", @"world", @"switch"],
    };
}

#pragma mark - Core: make the toolbar row horizontally scrollable

static const void *kScrollContainerKey = &kScrollContainerKey;
static const NSInteger kScrollViewTag  = 0x5758BEEF;

// Walk down (max `depth` levels) and take the first descendant holding at
// least two direct UIControl children: that is the actual button row.
static UIView *WXKBT_FindButtonRow(UIView *root, int depth) {
    if (root == nil || depth <= 0) return nil;
    NSUInteger direct = 0;
    for (UIView *sub in root.subviews) {
        if (sub.tag == kScrollViewTag) continue;
        if ([sub isKindOfClass:[UIControl class]]) direct++;
    }
    if (direct >= 2) return root;
    for (UIView *sub in root.subviews) {
        if (sub.tag == kScrollViewTag) continue;
        UIView *found = WXKBT_FindButtonRow(sub, depth - 1);
        if (found != nil) return found;
    }
    return nil;
}

// Reparent the row's UIControls into a lazily-created UIScrollView, preserving
// frames exactly. Idempotent: a row is only ever wrapped once.
static BOOL WXKBT_WrapButtonRow(UIView *row) {
    if (row == nil) return NO;
    if ([row isKindOfClass:[UIControl class]]) return NO;   // that is a button
    if (CGRectGetHeight(row.bounds) < 6.0) return NO;       // not laid out yet

    UIScrollView *scroll = (UIScrollView *)objc_getAssociatedObject(row, kScrollContainerKey);
    if (scroll == nil) {
        NSMutableArray<UIView *> *controls = [NSMutableArray array];
        for (UIView *sub in row.subviews) {
            if (sub.tag == kScrollViewTag) continue;
            if ([sub isKindOfClass:[UIControl class]]) [controls addObject:sub];
        }
        if (controls.count == 0) return NO;

        scroll = [[UIScrollView alloc] initWithFrame:row.bounds];
        scroll.showsHorizontalScrollIndicator = NO;
        scroll.showsVerticalScrollIndicator   = NO;
        scroll.bounces                        = YES;
        scroll.alwaysBounceHorizontal         = YES;
        scroll.backgroundColor                = [UIColor clearColor];
        scroll.userInteractionEnabled         = YES;
        scroll.multipleTouchEnabled           = NO;
        scroll.tag                            = kScrollViewTag;
        scroll.accessibilityIdentifier        = @"wxkbt_scroll_container";
        [row insertSubview:scroll atIndex:0];
        objc_setAssociatedObject(row, kScrollContainerKey, scroll,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        // Move the buttons. Frame preserved => icons / target-action / hit
        // testing stay byte-identical to the originals.
        for (UIView *btn in controls) {
            CGRect f = btn.frame;
            [btn removeFromSuperview];
            btn.frame = f;
            [scroll addSubview:btn];
        }
        NSLog(@"[WXKBT+] wrapped %s with %lu buttons into a scroll view",
              class_getName([row class]), (unsigned long)controls.count);
    }

    scroll.frame = row.bounds;
    CGFloat maxRight = 0;
    for (UIView *sub in scroll.subviews) {
        CGFloat r = CGRectGetMaxX(sub.frame);
        if (r > maxRight) maxRight = r;
    }
    scroll.contentSize = CGSizeMake(MAX(maxRight + 16.0, CGRectGetWidth(row.bounds)),
                                    CGRectGetHeight(row.bounds));
    scroll.contentInset = UIEdgeInsetsZero;

    // Visibility switches from PreferenceLoader (master switch off => no hiding)
    NSUserDefaults *def = WXKBT_Prefs();
    NSDictionary<NSString *, NSArray<NSString *> *> *keywordMap = WXKBT_KeywordMap();

    NSMutableArray<NSString *> *activeKeys = [NSMutableArray array];
    if (def != nil) {
        for (NSString *prefKey in keywordMap) {
            if ([def boolForKey:prefKey]) [activeKeys addObject:prefKey];
        }
    }

    for (UIView *btn in scroll.subviews) {
        BOOL hidden = NO;
        if (activeKeys.count > 0) {
            NSString *ident = WXKBT_IdentForButton(btn);
            for (NSString *prefKey in activeKeys) {
                if (WXKBT_MatchesKeyword(ident, keywordMap[prefKey])) { hidden = YES; break; }
            }
        }
        [btn setHidden:hidden];
    }
    return YES;
}

static BOOL WXKBT_WrapInScrollView(UIView *container) {
    if (container == nil) return NO;
    UIView *row = WXKBT_FindButtonRow(container, 6);
    if (row == nil) return NO;
    return WXKBT_WrapButtonRow(row);
}

#pragma mark - Dynamic hook: toolbar layoutSubviews

#define WXKBT_MAX_HOOKS 64
static Class gHookClasses[WXKBT_MAX_HOOKS];
static IMP   gHookOrig[WXKBT_MAX_HOOKS];
static int   gHookCount = 0;
static BOOL  gWrapping  = NO;   // re-entrancy guard, main thread only

static void WXKBT_layoutSubviews_hook(id self, SEL _cmd) {
    // Find the hooked class in this object's ancestry: our IMP can be reached
    // from a subclass that does not override -layoutSubviews itself.
    IMP orig = NULL;
    Class w = object_getClass(self);
    while (w != Nil && orig == NULL) {
        for (int i = 0; i < gHookCount; i++) {
            if (gHookClasses[i] == w) { orig = gHookOrig[i]; break; }
        }
        w = class_getSuperclass(w);
    }
    if (orig != NULL) ((void (*)(id, SEL))orig)(self, _cmd);

    if (gWrapping) return;
    gWrapping = YES;
    @autoreleasepool {
        @try {
            WXKBT_WrapInScrollView((UIView *)self);
        } @catch (NSException *e) {
            NSLog(@"[WXKBT+] wrap skipped: %@", e.reason);
        }
    }
    gWrapping = NO;
}

// Hook -layoutSubviews only on classes whose NAME looks like a toolbar row and
// that implement -layoutSubviews THEMSELVES. Cheap: no per-class method list
// copies, no strings, no allocation.
static int WXKBT_InstallLayoutHooks(NSMutableString *log) {
    SEL sel = @selector(layoutSubviews);
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (classes == NULL) return 0;

    int hooked = 0;
    for (unsigned int i = 0; i < count && gHookCount < WXKBT_MAX_HOOKS; i++) {
        Class cls = classes[i];
        const char *cn = class_getName(cls);
        if (cn == NULL || cn[0] == '\0' || cn[0] == '_') continue;
        if (!WXKBT_NameHas(cn, "toolbar") && !WXKBT_NameHas(cn, "funcbar") &&
            !WXKBT_NameHas(cn, "tool bar")) {
            continue;
        }
        if (!WXKBT_ClassIsSubclassOf(cls, "UIView")) continue;
        if (WXKBT_ClassIsSubclassOf(cls, "UIControl")) continue;   // it is a button
        if (!WXKBT_OwnsSelector(cls, sel)) continue;               // never touch UIKit

        Method m = class_getInstanceMethod(cls, sel);
        if (m == NULL) continue;
        IMP orig = method_getImplementation(m);

        gHookClasses[gHookCount] = cls;
        gHookOrig[gHookCount]    = orig;
        gHookCount++;
        hooked++;

        method_setImplementation(m, (IMP)WXKBT_layoutSubviews_hook);
        [log appendFormat:@"hooked -[%s layoutSubviews]\n", cn];
    }
    free(classes);
    return hooked;
}

#pragma mark - Dynamic hook: the "can't enable more than 7" gate

// Forcing a boolean gate to YES is only safe if the encoding really says BOOL,
// and only if the owning class is toolbar-related. Everything else is reported
// in the status file but never touched.
static BOOL WXKBT_ReturnTypeIsBool(const char *enc) {
    if (enc == NULL || enc[0] == '\0') return NO;
    return (enc[0] == 'B' || enc[0] == 'c');
}

static BOOL WXKBT_EncodingLooksLikeIntegerGetter(const char *enc) {
    if (enc == NULL || enc[0] == '\0') return NO;
    char c = enc[0];
    if (c != 'q' && c != 'Q' && c != 'i' && c != 'I' && c != 'l' && c != 'L') return NO;
    int colons = 0;
    for (const char *p = enc; *p != '\0'; p++) if (*p == ':') colons++;
    return colons == 1;
}

static BOOL WXKBT_ForcedBoolYES(id self, SEL _cmd, id a1, BOOL a2) {
    (void)self; (void)_cmd; (void)a1; (void)a2;
    return YES;
}

static long long WXKBT_ForcedCount(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return 999;
}

static BOOL WXKBT_ClassNameIsToolbarScoped(const char *cn) {
    return WXKBT_NameHas(cn, "toolbar") || WXKBT_NameHas(cn, "tool bar") ||
           WXKBT_NameHas(cn, "funcitem") || WXKBT_NameHas(cn, "toolbarpref");
}

// One single pass over the class list. Uses only O(1) selector lookups
// (class_getInstanceMethod / class_getSuperclass) — no class_copyMethodList,
// no NSString per selector. Reports every owner, hooks only what is safe.
static void WXKBT_InstallGateHooks(NSMutableString *log) {
    NSArray<NSString *> *gateSels = @[ @"canSetToolbarFunc:enabled:" ];
    NSArray<NSString *> *countSels = @[ @"maxCount", @"countLimit" ];
    BOOL uncapAllowed = WXKBT_ForceUncapEnabled();

    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (classes == NULL) return;

    [log appendString:@"\n--- selector owners found ---\n"];
    for (NSString *selName in gateSels) {
        SEL sel = NSSelectorFromString(selName);
        for (unsigned int i = 0; i < count; i++) {
            Class cls = classes[i];
            const char *cn = class_getName(cls);
            if (cn == NULL || cn[0] == '\0' || cn[0] == '_') continue;
            if (!WXKBT_OwnsSelector(cls, sel)) continue;

            Method m = class_getInstanceMethod(cls, sel);
            const char *enc = (m != NULL) ? method_getTypeEncoding(m) : NULL;
            BOOL safe = WXKBT_ClassNameIsToolbarScoped(cn) && WXKBT_ReturnTypeIsBool(enc);
            [log appendFormat:@"%@ %s -%s enc=%s\n",
                safe ? @"HOOK" : @"skip", cn, selName.UTF8String,
                (enc != NULL) ? enc : "?"];
            if (safe && uncapAllowed) {
                method_setImplementation(m, (IMP)WXKBT_ForcedBoolYES);
                NSLog(@"[WXKBT+] uncapped -[%s %@]", cn, selName);
            }
        }
    }
    for (NSString *selName in countSels) {
        SEL sel = NSSelectorFromString(selName);
        for (unsigned int i = 0; i < count; i++) {
            Class cls = classes[i];
            const char *cn = class_getName(cls);
            if (cn == NULL || cn[0] == '\0' || cn[0] == '_') continue;
            if (!WXKBT_ClassNameIsToolbarScoped(cn)) continue;
            if (!WXKBT_OwnsSelector(cls, sel)) continue;

            Method m = class_getInstanceMethod(cls, sel);
            const char *enc = (m != NULL) ? method_getTypeEncoding(m) : NULL;
            BOOL safe = WXKBT_EncodingLooksLikeIntegerGetter(enc);
            [log appendFormat:@"%@ %s -%s enc=%s\n",
                safe ? @"HOOK" : @"skip", cn, selName.UTF8String,
                (enc != NULL) ? enc : "?"];
            if (safe && uncapAllowed) {
                method_setImplementation(m, (IMP)WXKBT_ForcedCount);
                NSLog(@"[WXKBT+] raised -[%s %@] to 999", cn, selName);
            }
        }
    }
    free(classes);
}

#pragma mark - Best-effort immediate pass (app process only)

// The toolbar view may already exist by the time our worker thread installs the
// hooks, so give it a nudge instead of waiting for the next natural layout pass.
static void WXKBT_ForceInitialPass(void) {
    Class appCls = objc_getClass("UIApplication");
    if (appCls == Nil) return;
    id app = ((id (*)(id, SEL))objc_msgSend)((id)appCls,
                                             sel_registerName("sharedApplication"));
    if (app == nil) return;                 // app extension -> nothing to do

    id windows = ((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("windows"));
    if (![windows isKindOfClass:[NSArray class]]) return;

    for (UIView *win in (NSArray *)windows) {
        if (![win isKindOfClass:[UIView class]]) continue;
        [win setNeedsLayout];
        [win layoutIfNeeded];
    }
}

#pragma mark - Worker thread

static void *WXKBT_Worker(void *arg) {
    (void)arg;
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
        NSString *exec = [[NSBundle mainBundle] executablePath] ?: @"";
        BOOL isExtension = [bid hasSuffix:@".keyboard"] ||
                           [exec rangeOfString:@"wxkb_plugin"].location != NSNotFound;

        // Let the host app / extension finish launching. The keyboard extension
        // needs the toolbar sooner than the app needs its settings panel.
        sleep(isExtension ? 1 : 3);

        NSMutableString *log = [NSMutableString string];
        [log appendFormat:@"# wxkbt+ status\n"];

        // Safety net: even if some other injector loads us into a process we did
        // not ask for, we only ever touch WeType.
        BOOL isWeType = [bid hasPrefix:@"com.tencent.wetype"] ||
                        [exec rangeOfString:@"wxkb"].location != NSNotFound;
        if (!isWeType) {
            [log appendFormat:@"not WeType (bundle=%s), doing nothing\n", bid.UTF8String ?: ""];
            WXKBT_WriteStatus(@"wxkbt-status.txt", log);
            return NULL;
        }

        if (!WXKBT_MasterEnabled()) {
            [log appendString:@"master switch = OFF, doing nothing\n"];
            [log appendFormat:@"bundle=%s\n", bid.UTF8String ?: ""];
            WXKBT_WriteStatus(@"wxkbt-status.txt", log);
            return NULL;
        }

        [log appendFormat:@"bundle=%s\n", bid.UTF8String ?: ""];
        [log appendFormat:@"exec=%s\n", exec.UTF8String ?: ""];
        [log appendFormat:@"home=%s\n", NSHomeDirectory().UTF8String ?: ""];
        [log appendFormat:@"version=0.3.0\n\n"];

        int hooked = WXKBT_InstallLayoutHooks(log);
        [log appendFormat:@"\nlayout hooks installed: %d\n", hooked];

        WXKBT_InstallGateHooks(log);

        if (!isExtension) {
            @try { WXKBT_ForceInitialPass(); }
            @catch (NSException *e) { [log appendFormat:@"initial pass skipped: %@\n", e.reason]; }
        }

        WXKBT_WriteStatus(@"wxkbt-status.txt", log);
        NSLog(@"[WXKBT+] ready (hooks=%d, bundle=%@)", hooked, bid);
    }
    return NULL;
}

#pragma mark - Constructor

// NOTHING but thread creation happens here. A tweak constructor runs inside
// dyld's dlopen() while the global loader lock is held; doing real work here
// blocks every other thread's dlopen and gets the process killed by the
// launch watchdog (0x8BADF00D). This is exactly what v0.2.0 got wrong.
%ctor {
    pthread_attr_t attr;
    if (pthread_attr_init(&attr) != 0) return;
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_t thread;
    (void)pthread_create(&thread, &attr, WXKBT_Worker, NULL);
    pthread_attr_destroy(&attr);
}
