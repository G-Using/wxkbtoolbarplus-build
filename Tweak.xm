// WXKeyboardToolbarPlus  v0.5.0
// Theos + Logos tweak for WeType (微信输入法 / wxkb).
//
// ===========================================================================
// GROUND TRUTH (from on-device Mach-O dumps, not guesses)
// ===========================================================================
//   App          : wxkb.app
//                  bundle = com.tencent.wetype            exec = wxkb
//   Keyboard ext : wxkb.app/PlugIns/wxkb_plugin.appex
//                  bundle = com.tencent.wetype.keyboard   exec = wxkb_plugin
//
//   The class "WXKeyboardToolbarView" DOES NOT EXIST. Every build up to 0.1.7
//   hooked a nonexistent class, so it silently did nothing.
//
// ===========================================================================
// THE PROCESS SPLIT -- WHY 0.1.x - 0.3.x COULD NEVER WORK
// ===========================================================================
// THE KEYBOARD RUNS IN A SEPARATE PROCESS WITH A SEPARATE OBJC CLASS TABLE:
//
//   symbol                       wxkb_plugin   wxkb
//   ---------------------------  ------------  -----
//   WBFunctionToolBar                 yes       -
//   WBCustomToolBarView               yes       -
//   WBCustomToolBarScrolView          yes       -
//   WBPlusSelectionView               yes       -
//   WBControlItem / WBCCFuncItem      yes       -
//   WBToolbarPreferences              yes       yes
//   canSetToolbarFunc:enabled:         -       yes
//   isToolbarFuncEnabled:              -       yes
//
//   => Builds that hooked the toolbar view only ever ran in the host app,
//      which has no toolbar at all.
//   => Builds that hooked the 7-item gate could never run in the keyboard,
//      because that process does not contain the method.
//
// ===========================================================================
// WHAT v0.4.0 GOT WRONG -- "一闪一闪" (the periodic flicker)
// ===========================================================================
// Measured from the user's 58.6fps screen recording of WeType 3.5.3:
//
//   0.00-3.74s   the configured TEXT toolbar   (脚本 复制 粘贴 ... 收起)
//   3.74s        switches to the ICON toolbar  (P  ::  繁  Ai ...  ⌄)
//   7.63-7.76s   flicker #1: 5 blank frames, then 4 text frames, then icons
//  11.35-11.48s  flicker #2: same shape
//  15.15-15.31s  flicker #3: same shape
//
// Period is a constant ~3.75s. Sequence is always:
//     icon toolbar -> BLANK -> text toolbar -> icon toolbar
//
// The keyboard rebuilds its toolbar roughly every 3.75s and re-reads the list
// of "enabled" toolbar functions. v0.4.0 replaced the predicate
// -canSetToolbarFunc:enabled: with an unconditional `return YES`. That makes a
// function which is meant to be EXCLUDED look enabled during the rebuild, while
// its actual button object does not exist. The framework therefore first
// clears the row (the blank frame), then falls back to a reduced set (the text
// toolbar), then recovers on the next tick. Hence a repeating flash.
//
// LESSON: an unconditional `return YES` on a predicate is far more dangerous
// than leaving it alone. A gate predicate is not a boolean the caller only
// reads -- the rebuild path *derives the toolbar contents* from it. Faking it
// changes what gets built.
//
// ===========================================================================
// HOW v0.5.0 AVOIDS BOTH FAILURE MODES
// ===========================================================================
// 1. NO HOOKING BY DEFAULT. On a fresh install this tweak replaces exactly
//    zero methods. The keyboard is byte-for-byte stock: no flicker, no crash,
//    nothing to fall back from. It only observes and reports.
// 2. The gate hook is OPT-IN and, when enabled, is a guarded pass-through:
//    it calls the original predicate first and only overrides the specific
//    negative answer that means "you are at the cap". Any other NO is passed
//    through untouched, so no entry ever appears that the original code would
//    have excluded for a different reason.
// 3. Nothing is done on the launch path (%ctor spawns one thread and returns).
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
static NSString * const kPrefForceUncap = @"ForceUncap";    // BOOL opt-in gate override
static NSString * const kPrefVerbose    = @"VerboseScan";   // BOOL deep scan

// Bumped whenever the decision logic changes, so the status file proves which
// build the device is actually running.
static NSString * const kBuildTag = @"0.5.0";

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

static BOOL WXKBT_Bool(NSString *key, BOOL fallback) {
    NSUserDefaults *d = WXKBT_Prefs();
    if (d == nil) return fallback;
    if ([d objectForKey:key] == nil) return fallback;
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

#pragma mark - Guarded gate override (opt-in only)

// One slot per hooked method, so the passthrough can find the original.
#define WXKBT_MAX_HOOKS 16
static Class gGateClass[WXKBT_MAX_HOOKS];
static SEL   gGateSel[WXKBT_MAX_HOOKS];
static IMP   gGateOrig[WXKBT_MAX_HOOKS];
static int   gGateCount = 0;

static IMP WXKBT_OrigFor(Class cls, SEL sel) {
    for (int i = 0; i < gGateCount; i++) {
        if (gGateClass[i] == cls && sel_isEqual(gGateSel[i], sel)) return gGateOrig[i];
    }
    return NULL;
}

// A capability predicate of the form -foo:(id)bar enabled:(BOOL)flag.
//
// IMPORTANT: this is a PASS-THROUGH, not a blanket YES.
// It asks the original first. Only a NO that arrives while the second argument
// says "enabling" is overridden -- i.e. only the "you are at the cap" answer.
// Every other NO is returned unchanged, so the caller can never be told an
// entry is available that the original excluded for a different reason. This
// is what stops the toolbar-rebuild path from constructing an inconsistent
// function list (which is what produced the periodic flicker in v0.4.0).
static BOOL WXKBT_GatePassthrough(id self, SEL _cmd, id arg1, BOOL arg2) {
    Class cls = object_getClass(self);
    IMP orig = NULL;
    for (Class w = cls; w != Nil && orig == NULL; w = class_getSuperclass(w)) {
        orig = WXKBT_OrigFor(w, _cmd);
    }
    BOOL real = YES;
    if (orig != NULL) real = ((BOOL (*)(id, SEL, id, BOOL))orig)(self, _cmd, arg1, arg2);
    if (real) return YES;      // original already says yes -- do not interfere
    if (!arg2) return NO;      // this is a "cannot enable" query -- leave alone
    return YES;                // the one case we lift: enabling while at the cap
}

// -isToolbarFuncEnabled: takes a single argument.
static BOOL WXKBT_GatePassthrough1(id self, SEL _cmd, id arg1) {
    Class cls = object_getClass(self);
    IMP orig = NULL;
    for (Class w = cls; w != Nil && orig == NULL; w = class_getSuperclass(w)) {
        orig = WXKBT_OrigFor(w, _cmd);
    }
    if (orig == NULL) return YES;
    return ((BOOL (*)(id, SEL, id))orig)(self, _cmd, arg1);
}

#pragma mark - Gate installation (single pass, narrowly scoped, opt-in)

typedef struct {
    int considered;
    int hooked;
    int skipped;
} WXKBT_GateStats;

// Only ever called for a class that (a) is named toolbar-scoped, (b) OWNS the
// selector itself, and (c) declares it BOOL-returning. Everything else is
// logged and left completely alone.
static void WXKBT_ConsiderGateSelector(Class *classes, unsigned int count,
                                       NSString *selName, IMP replacement,
                                       int nargs, BOOL allowHook,
                                       NSMutableString *log, WXKBT_GateStats *stats) {
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

        BOOL scoped  = WXKBT_NameIsToolbarScoped(cn);
        BOOL isBool  = WXKBT_ReturnTypeIsBool(enc);
        BOOL isUIKit = WXKBT_ClassIsSubclassOf(cls, "UIView") && !WXKBT_NameHas(cn, "wb");
        BOOL safe    = scoped && isBool && !isUIKit && gGateCount < WXKBT_MAX_HOOKS;

        if (safe && allowHook) {
            gGateClass[gGateCount] = cls;
            gGateSel[gGateCount]   = sel;
            gGateOrig[gGateCount]  = method_getImplementation(m);
            gGateCount++;

            method_setImplementation(m, replacement);
            stats->hooked++;
            [log appendFormat:@"HOOKED  -[%s %@]  enc=%s  (guarded passthrough, %d args)\n",
             cn, selName, encText, nargs];
            NSLog(@"[WXKBT+] gate passthrough installed -[%s %@]", cn, selName);
        } else {
            stats->skipped++;
            [log appendFormat:@"%s  -[%s %@]  enc=%s  (scoped=%d bool=%d hook=%d)\n",
             safe ? @"NOT-HOOKED" : @"skip", cn, selName, encText,
             (int)scoped, (int)isBool, (int)allowHook];
        }
    }
}

#pragma mark - Read-only census

// Purely diagnostic: which of the known classes exist in THIS process? This is
// what proves the process split. Allocates nothing per selector.
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

// Opt-in only (Preferences -> Deep scan) and only ever run off the launch path.
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
            [log appendString:@"not WeType, doing nothing\n"];
            WXKBT_WriteStatus(@"wxkbt-status.txt", log);
            return NULL;
        }

        if (!WXKBT_Bool(kPrefEnabled, YES)) {
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
            // preferences / config (exist in both processes)
            @"WBToolbarPreferences", @"WBVoiceinputPreferences",
            // input view controllers
            @"WBInputViewController", @"WBMainInputView", @"WBRootInputView",
            // UIKit sanity check -- must be present everywhere
            @"UIView", @"UIResponder",
        ];

        // Always: cheap presence census. Every run tells us which half of the
        // process split we are in. No method lists are touched.
        WXKBT_CensusClasses(log, probeClasses);

        // ---- The gate pass, opt-in and guarded ------------------------------
        BOOL uncap = WXKBT_Bool(kPrefForceUncap, NO);   // DEFAULT OFF
        WXKBT_GateStats stats = {0, 0, 0};

        [log appendString:@"\n--- gate census ---\n"];
        unsigned int count = 0;
        Class *classes = objc_copyClassList(&count);
        if (classes != NULL) {
            [log appendFormat:@"loaded classes in this process: %u\n", count];
            [log appendFormat:@"forceUncap preference = %s\n", uncap ? "ON" : "OFF"];
            [log appendString:
                @"\nNOTE: the following selectors are only ever REPLACED when the\n"
                @"forceUncap preference is ON, and even then only as a guarded\n"
                @"passthrough (original is called first; only an at-the-cap NO is\n"
                @"lifted). With forceUncap OFF nothing is replaced at all.\n\n"];

            WXKBT_ConsiderGateSelector(classes, count,
                                       @"canSetToolbarFunc:enabled:", (IMP)WXKBT_GatePassthrough,
                                       2, uncap, log, &stats);
            WXKBT_ConsiderGateSelector(classes, count,
                                       @"isToolbarFuncEnabled:", (IMP)WXKBT_GatePassthrough1,
                                       1, uncap, log, &stats);
            WXKBT_ConsiderGateSelector(classes, count,
                                       @"setToolBarFunc:enabled:", (IMP)WXKBT_GatePassthrough,
                                       2, uncap, log, &stats);

            free(classes);
        } else {
            [log appendString:@"objc_copyClassList returned NULL\n"];
        }

        [log appendFormat:@"\ngate: considered=%d hooked=%d skipped=%d (forceUncap=%d)\n",
            stats.considered, stats.hooked, stats.skipped, (int)uncap];
        [log appendFormat:@"methods actually replaced in this process: %d\n", gGateCount];

        [log appendString:
            @"\n--- what to look for ---\n"
            @"If a 'HOOKED' line appears above while role=KEYBOARD EXTENSION, the cap\n"
            @"(or part of it) lives in the keyboard process and is now lifted.\n"
            @"If the gate census shows all skips and role=KEYBOARD EXTENSION, the cap\n"
            @"is enforced on a class not matching the toolbar-name filter, or it lives\n"
            @"in the host app's WBToolbarPreferences and reaches the keyboard over IPC.\n"
            @"In that case enable 'Deep scan' and report this file.\n"];

        if (WXKBT_Bool(kPrefVerbose, NO)) {
            @try { WXKBT_VerboseMethodDump(log, probeClasses); }
            @catch (NSException *e) {
                [log appendFormat:@"verbose dump skipped: %@\n", e.reason];
            }
        }

        WXKBT_WriteStatus(@"wxkbt-status.txt", log);
        NSLog(@"[WXKBT+] %@ ready (role=%@, replaced=%d, forceUncap=%d)",
              kBuildTag, isKeyboardExt ? @"kbd" : @"app", gGateCount, (int)uncap);
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
