// WXKeyboardToolbarPlus  v0.4.0
// Theos + Logos tweak for WeType (微信输入法 / wxkb).
//
// ===========================================================================
// GROUND TRUTH (from on-device Mach-O dumps, not guesses)
// ===========================================================================
//   App          : wrkb.app  .../2779C88A-.../wxkb.app
//                  bundle = com.tencent.wetype            exec = wxkb
//   Keyboard ext : wxkb.app/PlugIns/wxkb_plugin.appex
//                  bundle = com.tencent.wetype.keyboard   exec = wxkb_plugin
//
//   The class "WXKeyboardToolbarView" DOES NOT EXIST. Every build up to 0.1.7
//   hooked a nonexistent class, so it silently did nothing.
//
// ===========================================================================
// WHY EVERY BUILD UP TO 0.3.1 FAILED -- THE ACTUAL ROOT CAUSE
// ===========================================================================
// THE KEYBOARD RUNS IN A SEPARATE PROCESS.
//
//   com.tencent.wetype          -> wxkb        (host app: settings, login)
//   com.tencent.wetype.keyboard -> wxkb_plugin (THE KEYBOARD. Separate process,
//                                               separate dyld, separate injection.)
//
// The two binaries have DIFFERENT Objective-C class tables:
//
//   symbol                       wxkb_plugin   wxkb
//   ---------------------------  ------------  -----
//   WBFunctionToolBar                 yes       -
//   WBCustomToolBarView               yes       -
//   WBCustomToolBarScrolView          yes       -
//   WBPlusSelectionView               yes       -
//   WBControlItem / WBCCFuncItem      yes       -
//   canSetToolbarFunc:enabled:         -       yes
//   isToolbarFuncEnabled:              -       yes
//
// So every build that hooked the toolbar view worked on the host app (which
// has no toolbar at all), and every build that hooked the 7-item gate could
// never touch the keyboard, because the keyboard process does not contain
// that method. Meanwhile the "#1 suspect" -- hooking -[<toolbar view>
// layoutSubviews] in the *keyboard* process -- crashed the keyboard 1-2
// seconds after it appeared: our IMP was reachable from subclasses, we
// called the wrong original, and the re-entrancy guard let the recursive
// second pass through, where we stripped controls out from under a live
// layout pass. iOS then killed the extension and fell back to the native
// keyboard. That is exactly the reported symptom.
//
// ===========================================================================
// HOW v0.4.0 AVOIDS IT
// ===========================================================================
// 1. ZERO speculative Objective-C hooking. We never swizzle a UIKit class, we
//    never swap -layoutSubviews, we never reimplement a button. There is no
//    re-entrancy problem because there is nothing to re-enter.
// 2. The only method ever replaced is a ONE-LINE PREDICATE that is confirmed
//    BOOL and confirmed owned by a toolbar-scoped class at runtime.
// 3. We never move, reparent, resize or recreate a button. The native toolbar
//    is left 100% intact -- same class, same frame, same icons, same
//    target/action, same scroll view (WBCustomToolBarScrolView is already a
//    UIScrollView, so the native row is already horizontally scrollable).
// 4. Everything else is read-only diagnosis written to a status file.
// 5. %ctor does nothing but spawn a thread (see v0.2.0 post-mortem below).
//
// ===========================================================================
// WHY v0.2.0 CRASHED THE APP (wxkb-2026-09-28-224927.ips)
// ===========================================================================
//   EXC_CRASH / SIGKILL, FRONTBOARD 0x8BADF00D
//   "process-launch watchdog transgression: exhausted real (wall clock) time
//    allowance of 20.00 seconds", Elapsed total CPU time: 33.850s
//   main thread dispatch_once_wait, other thread dlopen_from ->
//   _os_unfair_lock_lock_slow (blocked on the dyld loader lock)
//
//   A tweak's %ctor runs INSIDE dyld's dlopen() with the global loader lock
//   held. v0.2.0 did four full passes over every loaded class plus a full
//   dump right there. => HARD RULE: %ctor spawns a thread and returns.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <pthread.h>
#import <unistd.h>
#import <string.h>
#import <stdlib.h>

#pragma mark - Preference keys

static NSString * const kPrefDomain     = @"com.gusing.wxkbtoolbarplus";
static NSString * const kPrefEnabled    = @"Enabled";       // BOOL master
static NSString * const kPrefForceUncap = @"ForceUncap";    // BOOL lift the 7 cap
static NSString * const kPrefVerbose    = @"VerboseScan";   // BOOL deep scan

// Bumped whenever the hook decision logic changes, so the status file proves
// which build the device is actually running.
static NSString * const kBuildTag = @"0.4.0";

#pragma mark - Small C helpers

// Case-insensitive substring test (no strcasestr dependency).
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
    for (Class w = cls; w != Nil; w = class_getSuperclass(w)) {
        if (w == sup) return YES;
    }
    return NO;
}

// YES when `cls` itself defines -sel rather than inheriting it.
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

// .xm compiles as Objective-C++; keep this spelled out rather than using the
// GNU `a ?: b` elision, which fails to parse in an argument list there.
static const char *WXKBT_CStr(NSString *s) {
    const char *c = s.UTF8String;
    return (c != NULL) ? c : "";
}

// Is this class name a toolbar / toolbar-gate owner we are willing to touch?
// Deliberately narrow: anything not matching here is reported, never hooked.
static BOOL WXKBT_NameIsToolbarScoped(const char *cn) {
    if (cn == NULL || cn[0] == '\0') return NO;
    return WXKBT_NameHas(cn, "toolbar") ||
           WXKBT_NameHas(cn, "tool bar") ||
           WXKBT_NameHas(cn, "functiontool") ||
           WXKBT_NameHas(cn, "funcitem");
}

static BOOL WXKBT_ReturnTypeIsBool(const char *enc) {
    if (enc == NULL || enc[0] == '\0') return NO;
    return (enc[0] == 'B' || enc[0] == 'c');
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

// Absent key => ON, so the tweak works out of the box while still giving the
// user a one-tap kill switch in Settings.
static BOOL WXKBT_BoolDefaultYes(NSString *key) {
    NSUserDefaults *d = WXKBT_Prefs();
    if (d == nil) return YES;
    if ([d objectForKey:key] == nil) return YES;
    return [d boolForKey:key];
}

#pragma mark - Sandbox-local diagnostics

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
        if ([body writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL]) {
            any = YES;
        }
    }
    return any;
}

#pragma mark - The one and only replacement IMP

// -canSetToolbarFunc:enabled: / -isToolbarFuncEnabled: are pure capability
// predicates: "may this toolbar function be switched on right now?". Returning
// YES changes no state, mutates no collection and calls nothing else, so it
// cannot corrupt an editing session -- it only removes the ceiling.
static BOOL WXKBT_GateReturnYES(id self, SEL _cmd, id arg1, BOOL arg2) {
    (void)self; (void)_cmd; (void)arg1; (void)arg2;
    return YES;
}

#pragma mark - Gate installation (single pass, narrowly scoped)

typedef struct {
    int  considered;
    int  hooked;
    int  skipped;
} WXKBT_GateStats;

// Only ever called for a class that (a) is named toolbar-scoped, (b) OWNS the
// selector itself, and (c) declares it BOOL-returning. Everything else is
// logged and left alone.
static void WXKBT_ConsiderGateSelector(Class *classes, unsigned int count,
                                       NSString *selName, IMP replacement,
                                       BOOL allowHook, NSMutableString *log,
                                       WXKBT_GateStats *stats) {
    SEL sel = NSSelectorFromString(selName);
    if (sel == NULL) return;

    for (unsigned int i = 0; i < count; i++) {
        Class cls = classes[i];
        const char *cn = class_getName(cls);
        if (cn == NULL || cn[0] == '\0' || cn[0] == '_') continue;
        if (!WXKBT_OwnsSelector(cls, sel)) continue;

        stats->considered++;

        Method m = class_getInstanceMethod(cls, sel);
        const char *enc = (m != NULL) ? method_getTypeEncoding(m) : NULL;
        const char *encText = (enc != NULL) ? enc : "?";

        BOOL scoped    = WXKBT_NameIsToolbarScoped(cn);
        BOOL isBool    = WXKBT_ReturnTypeIsBool(enc);
        BOOL isUIKit   = WXKBT_ClassIsSubclassOf(cls, "UIView") &&
                         !WXKBT_NameHas(cn, "wb");
        BOOL safe      = scoped && isBool && !isUIKit;

        if (safe && allowHook) {
            method_setImplementation(m, replacement);
            stats->hooked++;
            [log appendFormat:@"HOOKED  -[%s %@]  enc=%s\n", cn, selName, encText];
            NSLog(@"[WXKBT+] lifted gate -[%s %@]", cn, selName);
        } else {
            stats->skipped++;
            [log appendFormat:@"skip    -[%s %@]  enc=%s  (scoped=%d bool=%d)\n",
             cn, selName, encText, (int)scoped, (int)isBool];
        }
    }
}

#pragma mark - Read-only census

// Purely diagnostic: is the class even present in *this* process? This is what
// proves the process split, and it allocates nothing per selector.
static void WXKBT_CensusClasses(NSMutableString *log, NSArray<NSString *> *names) {
    NSUInteger present = 0;
    [log appendString:@"\n--- class census (presence only, no methods read) ---\n"];
    for (NSString *n in names) {
        Class cls = objc_getClass(n.UTF8String);
        if (cls == Nil) {
            [log appendFormat:@"  ABSENT  %@\n", n];
        } else {
            present++;
            Class sup = class_getSuperclass(cls);
            [log appendFormat:@"  present %@ : %s\n", n, (sup != Nil) ? class_getName(sup) : "-"];
        }
    }
    [log appendFormat:@"present %lu / %lu\n",
        (unsigned long)present, (unsigned long)names.count];
}

// Opt-in (Preferences -> Deep scan) and only ever run off the launch path.
static void WXKBT_VerboseMethodDump(NSMutableString *log, NSArray<NSString *> *names) {
    [log appendString:@"\n--- verbose method dump (opt-in) ---\n"];
    for (NSString *n in names) {
        Class cls = objc_getClass(n.UTF8String);
        if (cls == Nil) continue;
        [log appendFormat:@"\n=== %@ ===\n", n];
        unsigned int mc = 0;
        Method *ms = class_copyMethodList(cls, &mc);
        for (unsigned int i = 0; i < mc; i++) {
            const char *enc = method_getTypeEncoding(ms[i]);
            [log appendFormat:@"  -%s [%s]\n",
                sel_getName(method_getName(ms[i])), (enc != NULL) ? enc : "?"];
        }
        free(ms);
        unsigned int ic = 0;
        Ivar *ivs = class_copyIvarList(cls, &ic);
        for (unsigned int i = 0; i < ic; i++) {
            [log appendFormat:@"  ivar %s\n", ivar_getName(ivs[i])];
        }
        free(ivs);
    }
}

#pragma mark - Worker thread

static void *WXKBT_Worker(void *arg) {
    (void)arg;
    @autoreleasepool {
        NSString *bid  = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
        NSString *exec = [[NSBundle mainBundle] executablePath] ?: @"";
        BOOL isKeyboardExt = [bid hasSuffix:@".keyboard"] ||
                             [exec rangeOfString:@"wxkb_plugin"].location != NSNotFound;

        // Let the host finish launching before we touch anything.
        sleep(isKeyboardExt ? 2 : 3);

        NSMutableString *log = [NSMutableString string];
        [log appendString:@"# wxkbt+ status\n"];
        [log appendFormat:@"build=%s\n", WXKBT_CStr(kBuildTag)];
        [log appendFormat:@"bundle=%s\n", WXKBT_CStr(bid)];
        [log appendFormat:@"exec=%s\n", WXKBT_CStr(exec)];
        [log appendFormat:@"home=%s\n", WXKBT_CStr(NSHomeDirectory())];
        [log appendFormat:@"role=%s\n", isKeyboardExt ? "KEYBOARD EXTENSION" : "host app"];

        // Safety net: only ever touch WeType.
        BOOL isWeType = [bid hasPrefix:@"com.tencent.wetype"] ||
                        [exec rangeOfString:@"wxkb"].location != NSNotFound;
        if (!isWeType) {
            [log appendFormat:@"not WeType, doing nothing\n"];
            WXKBT_WriteStatus(@"wxkbt-status.txt", log);
            return NULL;
        }

        if (!WXKBT_BoolDefaultYes(kPrefEnabled)) {
            [log appendString:@"master switch = OFF -> no hooking\n"];
            WXKBT_WriteStatus(@"wxkbt-status.txt", log);
            return NULL;
        }

        NSArray<NSString *> *probeClasses = @[
            // toolbar row / container (expected in the KEYBOARD process)
            @"WBFunctionToolBar", @"WBCustomToolBarView", @"WBCustomToolBarScrolView",
            @"WBToolBarAuxiliary", @"WBTranslateViewToolBar", @"WBNavToolBarGroup",
            @"WBHorButtonGroupView", @"WBTopBar", @"WBKeyboardView",
            // buttons
            @"WBToolBarButton", @"WBCombinedToolBarButton", @"WBSplitReversedToolBarButton",
            @"WBTextPolishToolBarButton", @"WBFileTransferInviteStayToolBarButton",
            // "+" / add-function panel
            @"WBPlusSelectionView", @"WBPlusConfigAbilityItemView", @"WBControlPanelItemCell",
            @"WBControlItem", @"WBCCFuncItem", @"WBPanelConfig", @"WBCommonPanelView",
            // preferences / config (expected in the HOST app process)
            @"WBToolbarPreferences", @"WBVoiceinputPreferences",
            // input view controllers
            @"WBInputViewController", @"WBMainInputView", @"WBRootInputView",
            // UIKit sanity check -- must be present everywhere
            @"UIView", @"UIResponder",
        ];

        // Always: cheap presence census, so every run tells us which half of
        // the process split we are in. No method lists are touched.
        WXKBT_CensusClasses(log, probeClasses);

        // The gate pass. Exactly one class list copy, O(1) lookups per class,
        // no per-selector NSString, no class_copyMethodList.
        BOOL uncap = WXKBT_BoolDefaultYes(kPrefForceUncap);
        WXKBT_GateStats stats = {0, 0, 0};

        [log appendString:@"\n--- gate census ---\n"];
        unsigned int count = 0;
        Class *classes = objc_copyClassList(&count);
        if (classes != NULL) {
            [log appendFormat:@"loaded classes in this process: %u\n", count];

            // 1. The real 7-item ceiling. BOOL-returning capability predicates
            //    only -- no count/limit getters are faked, because returning a
            //    bogus number from an array-sizing or memory-budget method is
            //    how you turn an app into an over-release crash.
            WXKBT_ConsiderGateSelector(classes, count,
                                       @"canSetToolbarFunc:enabled:", (IMP)WXKBT_GateReturnYES,
                                       uncap, log, &stats);
            WXKBT_ConsiderGateSelector(classes, count,
                                       @"isToolbarFuncEnabled:", (IMP)WXKBT_GateReturnYES,
                                       uncap, log, &stats);
            WXKBT_ConsiderGateSelector(classes, count,
                                       @"setToolBarFunc:enabled:", (IMP)WXKBT_GateReturnYES,
                                       uncap, log, &stats);

            free(classes);
        } else {
            [log appendString:@"objc_copyClassList returned NULL\n"];
        }

        [log appendFormat:@"\ngate: considered=%d hooked=%d skipped=%d (uncap=%d)\n",
            stats.considered, stats.hooked, stats.skipped, (int)uncap];

        if (stats.hooked == 0) {
            [log appendString:@"\nNOTE: no gate selector owned by a toolbar-scoped "
                               @"BOOL predicate was found in THIS process. Report "
                               @"this file as-is -- the fix probably belongs in the "
                               @"other process (see class census above).\n"];
        }

        if (WXKBT_BoolDefaultYes(kPrefVerbose)) {
            @try { WXKBT_VerboseMethodDump(log, probeClasses); }
            @catch (NSException *e) {
                [log appendFormat:@"verbose dump skipped: %@\n", e.reason];
            }
        }

        WXKBT_WriteStatus(@"wxkbt-status.txt", log);
        NSLog(@"[WXKBT+] %@ ready (role=%@, hooked=%d)",
              kBuildTag, isKeyboardExt ? @"kbd" : @"app", stats.hooked);
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
