// WXKeyboardToolbarPlus  v0.6.0  --  PURE DIAGNOSTIC BUILD
// Theos + Logos tweak for WeType (微信输入法 / wxkb).
//
// ===========================================================================
// READ THIS FIRST: v0.6.0 REPLACES ZERO METHODS AND TOUCHES ZERO VIEWS.
// ===========================================================================
// This build exists to answer one question that three failed implementation
// attempts could not: WHERE IS THE 7-ITEM CAP, AND HOW DOES IT REACH THE
// KEYBOARD?
//
// It is deliberately crippled in three ways so that it cannot repeat any of
// the earlier failures:
//
//   1. IT DOES NOT INJECT INTO THE KEYBOARD. The filter lists only
//      com.tencent.wetype (the host app). The keyboard extension process is
//      left completely untouched. This is what removes the flicker: builds
//      <= 0.5.0 injected into wxkb_plugin as well.
//   2. IT NEVER CALLS objc_copyClassList(). That call takes the ObjC runtime
//      lock and forces +initialize on every loaded class. Inside a keyboard
//      extension several of those +initialize implementations register
//      timers / observers, and those side effects are what produced the
//      measured 3.75-second periodic toolbar rebuild. We now look up an
//      explicit list of class names instead -- O(list), no runtime walk, no
//      forced +initialize of unrelated classes.
//   3. IT ONLY READS. No method_setImplementation, no view manipulation.
//
// ===========================================================================
// WHY THE EARLIER BUILDS COULD NOT FIND THE CAP
// ===========================================================================
// The cap method -canSetToolbarFunc:enabled: exists ONLY in the host app
// (wxkb), never in the keyboard extension (wxkb_plugin). We confirmed this
// from the two on-device Mach-O dumps:
//
//   symbol                       wxkb_plugin   wxkb
//   ---------------------------  ------------  -----
//   WBFunctionToolBar                 yes       -
//   WBCustomToolBarView               yes       -
//   canSetToolbarFunc:enabled:         -       yes
//   isToolbarFuncEnabled:              -       yes
//
// But the host app's class list contains NO class called WBToolbarPreferences.
// Every build so far filtered candidate classes by requiring "toolbar" in the
// NAME, so the real owner was skipped every single time. This build therefore
// drops name filtering entirely and instead reports the actual owner of each
// interesting selector, whatever it is called.
//
// ===========================================================================
// HISTORY
// ===========================================================================
//  0.1.x  hooked WXKeyboardToolbarView, which DOES NOT EXIST. Did nothing.
//  0.2.0  did heavy work inside %ctor; held the dyld lock >20s and was killed
//         by the launch watchdog (0x8BADF00D, "application<com.tencent.wetype>
//         exhausted real (wall clock) time allowance of 20.00 seconds").
//  0.3.x  still only looked for toolbar-named classes; still never matched.
//  0.4.0  replaced the gate with an unconditional `return YES`. This fed an
//         inconsistent function list into the toolbar-rebuild path and caused
//         a ~3.75s flicker (icon row -> blank -> text row -> icon row).
//  0.5.0  made hooking opt-in and guarded, but STILL injected into the
//         keyboard, and still called objc_copyClassList -- so the flicker
//         survived. User confirmed: uninstall => no flicker, reinstall =>
//         flicker. The injection itself was the problem.
//  0.6.0  injects into the host app ONLY, never walks the class list, never
//         writes. Diagnostics only. => must be flicker-free.

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
static NSString * const kPrefVerbose    = @"VerboseScan";   // BOOL deep scan

static NSString * const kBuildTag = @"0.6.0-diag";

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

static BOOL WXKBT_BoolDefaultYes(NSString *key) {
    NSUserDefaults *d = WXKBT_Prefs();
    if (d == nil) return YES;
    if ([d objectForKey:key] == nil) return YES;
    return [d boolForKey:key];
}

#pragma mark - Sandbox-local output

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

#pragma mark - The probe list (explicit names, NO class-list walk)

// Every name here came from the on-device Mach-O dumps. Lookup is a plain
// objc_getClass() per name: O(n) hash lookups, no runtime lock held for long,
// and crucially no +initialize storm across unrelated classes.
static NSArray<NSString *> *WXKBT_ProbeClasses(void) {
    return @[
        // --- the cap predicates' likely owners (names guessed; we report the real one) ---
        @"WBToolbarPreferences", @"WBKeyboardRectPreferences", @"WBVoiceinputPreferences",
        @"WBPanelConfig", @"WBCommonPanelView",
        // --- toolbar views (host app has none; reported as ABSENT for contrast) ---
        @"WBFunctionToolBar", @"WBCustomToolBarView", @"WBCustomToolBarScrolView",
        @"WBToolBarAuxiliary", @"WBTranslateViewToolBar", @"WBNavToolBarGroup",
        @"WBHorButtonGroupView", @"WBTopBar", @"WBKeyboardView",
        // --- buttons ---
        @"WBToolBarButton", @"WBCombinedToolBarButton",
        // --- "+" / add-function panel ---
        @"WBPlusSelectionView", @"WBPlusConfigAbilityItemView", @"WBControlPanelItemCell",
        @"WBControlItem", @"WBCCFuncItem",
        // --- input view controllers ---
        @"WBInputViewController", @"WBMainInputView", @"WBRootInputView",
        // --- entry points that usually configure shared state ---
        @"WBKeyboardInputModeController", @"WBMigrationKeyboardViewManager",
        @"WBKeyboardRectUtil", @"WBMigrationKeyboardRectInfoHelper",
        // --- React Native bridge (settings face) ---
        @"WBMainRNViewController", @"WBRCTBundleManagerItem",
        // --- the keyboard extension's view controller, referenced by name from the app ---
        @"WBKeyboardViewController", @"KeyboardViewController",
        // --- sanity ---
        @"UIView", @"UIResponder", @"NSUserDefaults",
    ];
}

// Selectors whose OWNER we want to identify. This is the whole point of the
// build: we do not care what the class is called, only which class answers.
static NSArray<NSString *> *WXKBT_ProbeSelectors(void) {
    return @[
        @"canSetToolbarFunc:enabled:",
        @"isToolbarFuncEnabled:",
        @"setToolbarFunc:enabled:",
        @"toolbarFuncs",
        @"toolbarFuncsForScene:",
        @"setToolbarFuncs:",
        @"setToolbarFuncs:source:",
        @"saveToolbarFuncs:editingSource:",
        @"configItemCount",
        @"maxCount",
        @"countLimit",
    ];
}

#pragma mark - Reporting

// Which probe classes exist in THIS process? Presence only -- no method lists,
// no allocation per selector.
static void WXKBT_ReportCensus(NSMutableString *log, NSArray<NSString *> *names) {
    NSUInteger present = 0;
    [log appendString:@"\n=== class census (presence only) ===\n"];
    for (NSString *n in names) {
        Class cls = objc_getClass(n.UTF8String);
        if (cls == Nil) {
            [log appendFormat:@"  ABSENT   %@\n", n];
        } else {
            present++;
            Class sup = class_getSuperclass(cls);
            [log appendFormat:@"  present  %@ : %s\n", n, (sup != Nil) ? class_getName(sup) : "-"];
        }
    }
    [log appendFormat:@"  -> %lu / %lu present\n",
        (unsigned long)present, (unsigned long)names.count];
}

// The important part: for each selector of interest, report EVERY probe class
// that owns it, plus the superclass chain it actually resolves to. No name
// filter is applied here -- that filter is exactly what hid the owner before.
static void WXKBT_ReportSelectorOwners(NSMutableString *log,
                                       NSArray<NSString *> *classNames,
                                       NSArray<NSString *> *selNames) {
    [log appendString:@"\n=== selector ownership (no name filter) ===\n"];
    for (NSString *selName in selNames) {
        SEL sel = NSSelectorFromString(selName);
        if (sel == NULL) { [log appendFormat:@"\n-%@ : bad selector\n", selName]; continue; }

        BOOL anyOwner = NO;
        NSMutableString *block = [NSMutableString string];
        for (NSString *cn in classNames) {
            Class cls = objc_getClass(cn.UTF8String);
            if (cls == Nil) continue;
            if (!WXKBT_OwnsSelector(cls, sel)) continue;

            anyOwner = YES;
            Method m = class_getInstanceMethod(cls, sel);
            const char *enc = (m != NULL) ? method_getTypeEncoding(m) : NULL;
            Class sup = class_getSuperclass(cls);

            [block appendFormat:@"    OWNER    %@\n", cn];
            [block appendFormat:@"             super : %s\n",
                (sup != Nil) ? class_getName(sup) : "-"];
            [block appendFormat:@"             enc   : %s\n", (enc != NULL) ? enc : "?"];
            [block appendFormat:@"             isBOOL: %s\n",
                (enc != NULL && (enc[0] == 'B' || enc[0] == 'c')) ? "YES" : "no"];
            if (WXKBT_ClassIsSubclassOf(cls, "UIView")) {
                [block appendString:@"             note  : UIView subclass\n"];
            }
        }

        if (anyOwner) {
            [log appendFormat:@"\n  -%@\n", selName];
            [log appendString:block];
        } else {
            [log appendFormat:@"\n  -%@\n    (no probe class owns this)\n", selName];
        }
    }
}

// Dump the full method list + ivars of a single named class, on demand. Used
// only for the classes that turn out to own a cap selector.
static void WXKBT_ReportClassDetail(NSMutableString *log, NSString *className) {
    Class cls = objc_getClass(className.UTF8String);
    if (cls == Nil) {
        [log appendFormat:@"\n=== %@ : ABSENT ===\n", className];
        return;
    }
    Class sup = class_getSuperclass(cls);
    [log appendFormat:@"\n=== %@ : %s ===\n", className,
        (sup != Nil) ? class_getName(sup) : "-"];

    unsigned int mc = 0;
    Method *ms = class_copyMethodList(cls, &mc);
    [log appendFormat:@"  instance methods: %u\n", mc];
    for (unsigned int i = 0; i < mc; i++) {
        const char *nm = sel_getName(method_getName(ms[i]));
        const char *le = method_getTypeEncoding(ms[i]);
        // Only print the interesting ones to keep the file readable.
        if (WXKBT_NameHas(nm, "toolbar") || WXKBT_NameHas(nm, "func") ||
            WXKBT_NameHas(nm, "count") || WXKBT_NameHas(nm, "limit") ||
            WXKBT_NameHas(nm, "enabled") || WXKBT_NameHas(nm, "scene")) {
            [log appendFormat:@"    -%s  [%s]\n", nm, (le != NULL) ? le : "?"];
        }
    }
    free(ms);

    unsigned int ic = 0;
    Ivar *ivs = class_copyIvarList(cls, &ic);
    [log appendFormat:@"  ivars: %u\n", ic];
    for (unsigned int i = 0; i < ic; i++) {
        const char *nm = ivar_getName(ivs[i]);
        const char *te = ivar_getTypeEncoding(ivs[i]);
        if (nm != NULL && (WXKBT_NameHas(nm, "toolbar") || WXKBT_NameHas(nm, "func") ||
                           WXKBT_NameHas(nm, "count") || WXKBT_NameHas(nm, "limit"))) {
            [log appendFormat:@"    ivar %s  [%s]\n", nm, (te != NULL) ? te : "?"];
        }
    }
    free(ivs);
}

// Which on-disk / defaults stores are reachable, and do they hold toolbar keys?
// The cap very likely arrives at the keyboard through shared state, so this is
// where we look next.
static void WXKBT_ReportSharedState(NSMutableString *log) {
    [log appendString:@"\n=== shared state inventory ===\n"];

    // 1. Our own domain
    NSUserDefaults *own = [[NSUserDefaults alloc] initWithSuiteName:kPrefDomain];
    [log appendFormat:@"  own domain %@ readable: %s\n", kPrefDomain,
        (own != nil) ? "yes" : "no"];

    // 2. Standard defaults for this process -- key names only, values may be
    //    large; we only report keys that look toolbar/func related.
    NSUserDefaults *std = [NSUserDefaults standardUserDefaults];
    NSDictionary *all = [std dictionaryRepresentation];
    [log appendFormat:@"  standardUserDefaults keys: %lu\n", (unsigned long)all.count];
    NSUInteger hits = 0;
    for (NSString *k in all) {
        if (WXKBT_NameHas(k.UTF8String, "toolbar") || WXKBT_NameHas(k.UTF8String, "func") ||
            WXKBT_NameHas(k.UTF8String, "keyboard") || WXKBT_NameHas(k.UTF8String, "panel")) {
            id v = all[k];
            NSString *desc = [v description];
            if (desc.length > 160) desc = [[desc substringToIndex:160] stringByAppendingString:@"..."];
            [log appendFormat:@"    KEY %@ = %@\n", k, desc];
            hits++;
        }
    }
    [log appendFormat:@"    (toolbar/func/keyboard/panel related keys: %lu)\n", (unsigned long)hits];

    // 3. Common App Group containers -- this is the usual mechanism for sharing
    //    settings between a host app and its keyboard extension.
    NSArray<NSString *> *groups = @[
        @"group.com.tencent.wetype",
        @"group.com.tencent.wetype.keyboard",
        @"group.com.tencent.wxkb",
        @"group.com.tencent.WeType",
    ];
    for (NSString *g in groups) {
        NSUserDefaults *gd = [[NSUserDefaults alloc] initWithSuiteName:g];
        NSDictionary *gdAll = [gd dictionaryRepresentation];
        [log appendFormat:@"  app group %@ : %lu keys\n", g, (unsigned long)gdAll.count];
        for (NSString *k in gdAll) {
            if (WXKBT_NameHas(k.UTF8String, "toolbar") || WXKBT_NameHas(k.UTF8String, "func")) {
                id v = gdAll[k];
                NSString *desc = [v description];
                if (desc.length > 200) desc = [[desc substringToIndex:200] stringByAppendingString:@"..."];
                [log appendFormat:@"    KEY %@ = %@\n", k, desc];
            }
        }
    }

    // 4. The app's own container, looking for a config db / plist that the
    //    keyboard might read too.
    NSString *home = NSHomeDirectory();
    [log appendFormat:@"  container path: %s\n", WXKBT_CStr(home)];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *subdirs = @[@"Documents", @"Library/Preferences", @"Library/Application Support", @"Library/Caches"];
    for (NSString *sub in subdirs) {
        NSString *dir = [home stringByAppendingPathComponent:sub];
        NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:dir error:NULL];
        [log appendFormat:@"  %@ : %lu items\n", sub, (unsigned long)items.count];
        for (NSString *it in items) {
            if (WXKBT_NameHas(it.UTF8String, "toolbar") || WXKBT_NameHas(it.UTF8String, "func") ||
                WXKBT_NameHas(it.UTF8String, "keyboard") || WXKBT_NameHas(it.UTF8String, "config") ||
                WXKBT_NameHas(it.UTF8String, "setting") || WXKBT_NameHas(it.UTF8String, "wxkb")) {
                [log appendFormat:@"      * %@\n", it];
            }
        }
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

        sleep(2);

        NSMutableString *log = [NSMutableString string];
        [log appendString:@"# wxkbt+ DIAGNOSTIC status (v0.6.0)\n"];
        [log appendFormat:@"build=%s\n", WXKBT_CStr(kBuildTag)];
        [log appendFormat:@"bundle=%s\n", WXKBT_CStr(bid)];
        [log appendFormat:@"exec=%s\n", WXKBT_CStr(exec)];
        [log appendFormat:@"role=%s\n", isKeyboardExt ? "KEYBOARD EXTENSION" : "host app"];
        [log appendFormat:@"home=%s\n", WXKBT_CStr(NSHomeDirectory())];
        [log appendString:
            @"hooked=NONE (this build replaces zero methods by design)\n"
            @"classListWalk=NO  (objc_copyClassList is never called)\n"];

        BOOL isWeType = [bid hasPrefix:@"com.tencent.wetype"] ||
                        [exec rangeOfString:@"wxkb"].location != NSNotFound;
        if (!isWeType) {
            [log appendString:@"not WeType, doing nothing\n"];
            WXKBT_WriteStatus(@"wxkbt-status.txt", log);
            return NULL;
        }

        if (!WXKBT_BoolDefaultYes(kPrefEnabled)) {
            [log appendString:@"master switch = OFF\n"];
            WXKBT_WriteStatus(@"wxkbt-status.txt", log);
            return NULL;
        }

        NSArray<NSString *> *classes  = WXKBT_ProbeClasses();
        NSArray<NSString *> *sels     = WXKBT_ProbeSelectors();

        WXKBT_ReportCensus(log, classes);
        WXKBT_ReportSelectorOwners(log, classes, sels);

        // Detail dump for whichever probe classes actually own a cap selector.
        [log appendString:@"\n=== detail of classes owning cap selectors ===\n"];
        for (NSString *cn in classes) {
            Class cls = objc_getClass(cn.UTF8String);
            if (cls == Nil) continue;
            SEL capSel = NSSelectorFromString(@"canSetToolbarFunc:enabled:");
            SEL enSel  = NSSelectorFromString(@"isToolbarFuncEnabled:");
            if (WXKBT_OwnsSelector(cls, capSel) || WXKBT_OwnsSelector(cls, enSel)) {
                WXKBT_ReportClassDetail(log, cn);
            }
        }

        WXKBT_ReportSharedState(log);

        [log appendString:
            @"\n=== what we now need to know ===\n"
            @"1. Which class OWNS canSetToolbarFunc:enabled: in the host app?\n"
            @"   (Look under '=== selector ownership ==='.)\n"
            @"2. What is that class's superclass, and is it a preference/config store?\n"
            @"3. Does any app group or preferences file carry a toolbar function list?\n"
            @"   (Look under '=== shared state inventory ==='.)\n"
            @"4. Is there a numeric cap constant near the owner?\n"
            @"Once we know the owner's real name and the shared channel, the fix\n"
            @"belongs in the host app and does NOT need to touch the keyboard.\n"];

        if (WXKBT_BoolDefaultYes(kPrefVerbose)) {
            [log appendString:@"\n=== verbose class detail (opt-in) ===\n"];
            for (NSString *cn in classes) { WXKBT_ReportClassDetail(log, cn); }
        }

        WXKBT_WriteStatus(@"wxkbt-status.txt", log);
        NSLog(@"[WXKBT+] %@ diag done (role=%@)", kBuildTag,
              isKeyboardExt ? @"kbd" : @"app");
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
