// WXKeyboardToolbarPlus  v0.7.0  --  RUNTIME VALUE DIAGNOSTIC
// Theos + Logos tweak for WeType (微信输入法 / wxkb).
//
// ===========================================================================
// WHY v0.7.0 EXISTS
// ===========================================================================
// v0.6.0 scanned the HOST APP only. That was a mistake: re-reading the two
// on-device Mach-O dumps showed the 7-button cap does NOT live in the host
// app. The host app only carries a policy predicate -canSetToolbarFunc:enabled:
// The actual toolbar machinery is a keyboard-extension thing:
//
//   symbol / class              wxkb_plugin   wxkb (host)
//   --------------------------  ------------  -----------
//   WBToolbarPreferences             yes          -
//   WBFunctionToolBar                yes          -
//   WBCustomToolBarView              yes          -
//   WBCustomToolBarScrolView         yes          -
//   WBControlItem / WBCCFuncItem     yes          -
//   WBPlusSelectionView              yes          -
//   WBToolBarButton                  yes          -
//   setToolbarFuncs:                 yes          -
//   setToolbarFuncs:source:          yes          -
//   toolbarFuncs / _toolbarFuncs     yes          -
//   toolbarFuncsForScene:            yes          -
//   maxCount / _maxCount             yes          -
//   countLimit / _countLimit         yes          -
//   itemCount / _itemCount           yes          -
//   configItemCount                  yes          -
//   canSetToolbarFunc:enabled:        -          yes
//
// So EVERY version so far has been aiming at the wrong process. The fix has
// to run inside the keyboard extension. There is no way around that.
//
// ===========================================================================
// THE FLICKER CONSTRAINT -- AND WHY THIS BUILD IS STILL SAFE
// ===========================================================================
// We proved (user uninstall test) that merely injecting a dylib into
// wxkb_plugin made the toolbar flicker on a ~3.75s period. But v0.5.0 also
// called objc_copyClassList(), which takes the ObjC runtime lock and forces
// +initialize across EVERY loaded class -- some of those register timers.
// That is a far heavier perturbation than merely being present.
//
// v0.7.0 therefore returns to the keyboard, but with the lightest possible
// footprint so we can separate the two effects:
//
//   1. ZERO hooks. No method_setImplementation. (verified in the import table)
//   2. NO objc_copyClassList. Explicit objc_getClass() on a fixed name list.
//   3. All work happens ONCE, on a detached thread, 3s after launch, after the
//      keyboard has already drawn its first frame. Nothing on the hot path.
//
// If v0.7.0 does NOT flicker, the flicker was the copyClassList +initialize
// storm, and a hooking build can be made safe the same way. If it DOES
// flicker, injection alone is fatal and we must pursue a non-injection route
// (e.g. rewriting the app group / prefs the keyboard reads).
//
// ===========================================================================
// WHAT THIS BUILD READS (read-only, but it reads VALUES not just names)
// ===========================================================================
// The earlier builds only ever asked "does class X own selector Y". That is
// not enough -- a cap can live in a constant that no selector exposes. So we
// now also:
//   - call the getters that exist (maxCount, countLimit, itemCount,
//     configItemCount, toolbarFuncs, toolbarFuncsForScene:) and print the
//     REAL returned number/array, with its count and element descriptions;
//   - dump the full method + ivar list of WBToolbarPreferences;
//   - enumerate the container's files and the app-group defaults that look
//     toolbar-related.
// The returned value tells us which knob is the actual 7.
//
// ===========================================================================
// HISTORY
// ===========================================================================
//  0.1.x  hooked WXKeyboardToolbarView, which DOES NOT EXIST. Did nothing.
//  0.2.0  did heavy work inside %ctor; held the dyld lock past the 20s launch
//         watchdog (0x8BADF00D).
//  0.3.1  layoutSubviews re-entrancy bug stripped controls mid-layout => the
//         keyboard extension was killed => "flash, back to native keyboard".
//  0.4.0  replaced the gate with an unconditional `return YES`, feeding an
//         inconsistent function list into the rebuild path => ~3.75s flicker.
//  0.5.0  opted into guarded passthrough, but still injected the keyboard AND
//         still called objc_copyClassList -- flicker survived.
//  0.6.0  host-app-only read-only scan. Correct that it stopped the flicker,
//         wrong that it could ever find the cap (cap is not in that process).
//  0.7.0  back into the keyboard, still read-only, but now printing VALUES
//         and dumping WBToolbarPreferences in full.
//
// LESSON CARRIED FORWARD: never call objc_copyClassList in a keyboard
// extension, and never do real work in %ctor.

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

static NSString * const kBuildTag = @"0.8.1-kbdonscreen";

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

// YES when `cls` itself defines -sel rather than merely inheriting it.
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

// Trim a description so one huge object cannot bloat the report.
static NSString *WXKBT_Trim(id obj, NSUInteger max) {
    if (obj == nil) return @"(nil)";
    NSString *d;
    @try {
        d = [obj description];
    } @catch (__unused NSException *e) {
        return @"(description threw)";
    }
    if (d == nil) return @"(nil desc)";
    if (d.length > max) {
        return [[d substringToIndex:max] stringByAppendingString:@"..."];
    }
    return d;
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

#pragma mark - Output (multi-path, with a guaranteed fallback)

// v0.7.1 tried /var/mobile/Documents + app groups and the user found NOTHING.
// That means every candidate path was refused by the app sandbox. A
// sandboxed keyboard extension really is denied all of /var/mobile/*, and
// containerURLForSecurityApplicationGroupIdentifier: returns nil unless the
// extension's entitlements name that exact group -- which we cannot know.
//
// v0.7.2 therefore stops guessing and uses paths that cannot fail:
//
//   A. Our OWN container. NSHomeDirectory() in a sandboxed extension is
//      always writable -- it IS our data container. Filza can reach it, the
//      only annoyance is the UUID in the middle.
//      -> we ALSO record the real path into NSUserDefaults, and the HOST APP
//         (whose container has a *stable*, jailbreak-readable location too)
//         writes its own copy.
//
//   B. The host app's container. The app is the SAME app bundle and its
//      container is reachable. We locate it by asking the shared app group
//      first, then by scanning /var/mobile/Containers/Data/Application for a
//      .com.apple.mobile_container_manager.metadata.plist whose identifier is
//      com.tencent.wetype. That scan is a plain directory walk -- allowed
//      even from a sandboxed process on a jailbroken device where the
//      sandbox is relaxed, and harmless when it is not.
//
//   C. /var/mobile/Documents and friends, kept as a bonus (worked for root).
//
// Whatever succeeds is written into the report footer, AND the single most
// useful thing -- the exact filesystem path -- is pushed into NSUserDefaults
// so the Settings panel can show it and the user can copy it.

static NSArray<NSString *> *WXKBT_FindHostContainers(void);

static NSArray<NSString *> *WXKBT_OutputDirs(void) {
    NSMutableArray<NSString *> *dirs = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];

    // A. Our own container: always writable, guaranteed.
    NSString *home = NSHomeDirectory();
    if (home.length > 0) {
        [dirs addObject:home];
        [dirs addObject:[home stringByAppendingPathComponent:@"Documents"]];
        [dirs addObject:[home stringByAppendingPathComponent:@"Library/Caches"]];
    }
    NSString *tmp = NSTemporaryDirectory();
    if (tmp.length > 0) [dirs addObject:tmp];

    // B. App-group containers, if the entitlements happen to include one.
    for (NSString *g in @[@"group.com.tencent.wetype",
                          @"group.com.tencent.wetype.keyboard",
                          @"group.com.tencent.wxkb"]) {
        NSURL *u = [fm containerURLForSecurityApplicationGroupIdentifier:g];
        if (u != nil && u.path.length > 0) [dirs addObject:u.path];
    }

    // C. Locate the HOST APP's data container by scanning the container root
    //    for a metadata plist that names com.tencent.wetype. This gives us a
    //    path OUTSIDE our own sandbox that is often still writable on a
    //    jailbroken device, and whose location the user can find by just
    //    opening the wxkb app folder in Filza.
    [dirs addObjectsFromArray:WXKBT_FindHostContainers()];

    // D. Classic jailbreak drop points (worked for root processes).
    [dirs addObject:@"/var/mobile/Documents"];
    [dirs addObject:@"/var/mobile/Library/Preferences"];
    [dirs addObject:@"/var/mobile/Media"];
    [dirs addObject:@"/var/mobile/Library/Caches"];
    [dirs addObject:@"/tmp"];

    return dirs;
}

// Walk the data-container root and return the Documents dir of every app
// whose identifier starts with com.tencent.wetype.
static NSArray<NSString *> *WXKBT_FindHostContainers(void) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = @"/var/mobile/Containers/Data/Application";
    NSArray<NSString *> *subs = [fm contentsOfDirectoryAtPath:root error:NULL];
    for (NSString *uuid in subs) {
        if (uuid.length < 30) continue;              // UUIDs are 36 chars
        NSString *meta = [root stringByAppendingPathComponent:
                          [uuid stringByAppendingPathComponent:
                           @".com.apple.mobile_container_manager.metadata.plist"]];
        NSDictionary *pl = [NSDictionary dictionaryWithContentsOfFile:meta];
        if (pl == nil) continue;
        NSString *ident = pl[@"MCMMetadataIdentifier"];
        if (ident == nil) ident = pl[@"MCMMetadataIdentifier"];
        if (![ident isKindOfClass:[NSString class]]) continue;
        if (![ident hasPrefix:@"com.tencent.wetype"]) continue;
        NSString *base = [root stringByAppendingPathComponent:uuid];
        [out addObject:[base stringByAppendingPathComponent:@"Documents"]];
        [out addObject:[base stringByAppendingPathComponent:@"tmp"]];
        [out addObject:base];
    }
    return out;
}

// Remember the first path that worked so the other process (and the user) can
// find it. Stored in our pref domain, readable from Settings and from Filza at
// /var/mobile/Library/Preferences/com.gusing.wxkbtoolbarplus.plist.
static void WXKBT_NoteLocation(NSString *path) {
    if (path.length == 0) return;
    NSUserDefaults *d = WXKBT_Prefs();
    if (d == nil) return;
    NSString *key = @"LastReportPath";
    NSString *prev = [d stringForKey:key];
    if (prev != nil && ![prev isEqualToString:path]) {
        [d setObject:path forKey:@"PreviousReportPath"];
    }
    [d setObject:path forKey:key];
    [d synchronize];
}

static BOOL WXKBT_WriteStatus(NSString *basename, NSString *body) {
    if (basename.length == 0 || body.length == 0) return NO;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSData *data = [body dataUsingEncoding:NSUTF8StringEncoding];
    if (data == nil) return NO;
    BOOL any = NO;

    for (NSString *dir in WXKBT_OutputDirs()) {
        if (dir.length == 0) continue;
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:dir isDirectory:&isDir]) {
            [fm createDirectoryAtPath:dir withIntermediateDirectories:YES
                           attributes:nil error:NULL];
        }
        if (![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir) continue;

        NSString *path = [dir stringByAppendingPathComponent:basename];

        // NON-atomic write. `writeToFile:atomically:YES` creates a temp file
        // and rename()s it; inside a jailbroken extension sandbox that rename
        // can be denied even when plain writing is allowed. Write directly.
        BOOL ok = [data writeToFile:path options:0 error:NULL];
        if (!ok) {
            ok = [body writeToFile:path atomically:NO
                          encoding:NSUTF8StringEncoding error:NULL];
        }
        if (ok) {
            any = YES;
            WXKBT_NoteLocation(path);
        }
    }

    // Absolute last resort, and the one channel that cannot be sandboxed:
    // push the report through the system log. On a jailbroken device this is
    // readable from a shell / from Cr4shed / from Console, and it also lets
    // the user grab it with `idevicesyslog` or Filza's syslog viewer.
    if (!any) {
        NSString *one = [body stringByReplacingOccurrencesOfString:@"\n" withString:@" | "];
        NSLog(@"[WXKBT-REPORT-BEGIN] %@", one);
    }
    return any;
}

// Same body, but also written under a role-suffixed name so app and keyboard
// do not clobber each other. Called as WXKBT_WriteStatusForRole(@"kbd").
static BOOL WXKBT_WriteStatusForRole(NSString *role, NSString *body) {
    BOOL a = WXKBT_WriteStatus(@"wxkbt-status.txt", body);
    BOOL b = WXKBT_WriteStatus([NSString stringWithFormat:@"wxkbt-status-%@.txt", role], body);
    return (a || b);
}

#pragma mark - The probe lists (explicit names, NO class-list walk)

// Classes worth asking about. Split into groups so the report is readable.
// Every name is taken from the on-device Mach-O dumps -- no guessing.
static NSArray<NSString *> *WXKBT_ProbeClasses(void) {
    return @[
        // --- the config store: most likely home of the cap ---
        @"WBToolbarPreferences",
        @"WBKeyboardRectPreferences",
        @"WBVoiceinputPreferences",
        @"WBEmojiPreferences",
        @"WBPasteboardPreferences",
        @"WBPanelConfig",
        // --- the toolbar itself ---
        @"WBFunctionToolBar",
        @"WBCustomToolBarView",
        @"WBCustomToolBarScrolView",
        @"WBToolBarAuxiliary",
        @"WBToolBarButton",
        @"WBCombinedToolBarButton",
        @"WBNavToolBarGroup",
        @"WBSplitReversedToolBarButton",
        @"WBTranslateViewToolBar",
        @"WBTextPolishToolBarButton",
        @"WBFileTransferInviteStayToolBarButton",
        // --- the "+" panel that lists addable functions ---
        @"WBPlusSelectionView",
        @"WBPlusConfigAbilityItemView",
        @"WBControlItem",
        @"WBCCFuncItem",
        // --- input views ---
        @"WBMainInputView",
        @"WBRootInputView",
        @"WBEditorInputView",
        @"WBInputViewController",
        @"WBKeyboardViewController",
        @"KeyboardViewController",
        // --- misc ---
        @"WBKeyboardRectUtil",
        @"WBArrangeView",
        // --- newly spotted: toolbar bookkeeping / undo-button sizing ---
        @"WBTopBarTipsView",
        @"WBMoreCandidateBaseView",
        @"WBLogoIconPlus",
        @"WBSegmentControlItem",
        @"WBQuickSettingItemView",
        @"WBAskAIViewDriver",
        // --- sanity anchors ---
        @"UIView", @"UIControl", @"NSUserDefaults", @"NSObject",
    ];
}

// Selectors whose OWNER we want to identify. Includes every plausible variant
// of "count / limit / max" plus the toolbar-function accessors.
static NSArray<NSString *> *WXKBT_ProbeSelectors(void) {
    return @[
        // accessors for the function list
        @"toolbarFuncs",
        @"setToolbarFuncs:",
        @"setToolbarFuncs:source:",
        @"toolbarFuncsForScene:",
        @"toolbarFuncsForScene:suggestedTypes:prefersRecent:",
        @"saveToolbarFuncs:editingSource:",
        @"setToolBarFunc:toolbarFuncs:enabled:",
        @"setToolBarFunc:enabled:",
        @"handleToolBarFuncEvent:suggestedType:controlEvent:",
        @"updateEdittingToolbarFuncs:",
        // the myriad count/limit names seen in the dump
        @"maxCount",
        @"setMaxCount:",
        @"countLimit",
        @"setCountLimit:",
        @"itemCount",
        @"setItemCount:",
        @"configItemCount",
        @"hotWordMaxCount",
        @"validateHotWordAdditionWithCurrentCount:maxCount:",
        // extra toolbar-internal names found in the keyboard dump -- any of
        // these could be the real count the toolbar clamps against
        @"editToolbarItemTipsCount",
        @"setEditToolbarItemTipsCount:",
        @"isToolbarDisplayingFunc:",
        @"restoreToolbarButtonsAfterVoiceFocusEnd",
        @"functionRemoveFromToolbarByUserInteractions",
        @"recordFunctionRemoveFromToolbarByUserInteraction:",
        @"initWithMaxCount:sleepTime:",
        @"mainToolbarViewSizeDidChange:",
        // host-app-only policy predicate, for contrast
        @"canSetToolbarFunc:enabled:",
        @"isToolbarFuncEnabled:",
    ];
}

// Getters we will actually CALL, because a name tells us nothing about the
// number. Encodings: i=int32, q=int64, Q=uint64, I=uint32, l=long, B/c=BOOL,
// @=object. We only call the numeric/object ones.
static NSArray<NSString *> *WXKBT_CallableGetters(void) {
    return @[
        @"maxCount",
        @"countLimit",
        @"itemCount",
        @"configItemCount",
        @"hotWordMaxCount",
        @"editToolbarItemTipsCount",
        @"toolBarMutiDeviceSyncShowCount",
        @"toolbarFuncs",
        @"toolbarFuncRecentDisplaying",
    ];
}

#pragma mark - Reporting

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
            [log appendFormat:@"  present  %@ : %s\n", n,
                (sup != Nil) ? class_getName(sup) : "-"];
        }
    }
    [log appendFormat:@"  -> %lu / %lu present\n",
        (unsigned long)present, (unsigned long)names.count];
}

// For each selector of interest, report EVERY probe class that owns it. No
// name filter -- that filter is what hid the owner in earlier builds.
static void WXKBT_ReportSelectorOwners(NSMutableString *log,
                                       NSArray<NSString *> *classNames,
                                       NSArray<NSString *> *selNames) {
    [log appendString:@"\n=== selector ownership (no name filter) ===\n"];
    for (NSString *selName in selNames) {
        SEL sel = NSSelectorFromString(selName);
        if (sel == NULL) { [log appendFormat:@"\n  -%@ : bad selector\n", selName]; continue; }

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

            [block appendFormat:@"      OWNER %@  (super %s)\n", cn,
                (sup != Nil) ? class_getName(sup) : "-"];
            [block appendFormat:@"            enc %s\n",
                (enc != NULL) ? enc : "?"];
        }

        if (anyOwner) {
            [log appendFormat:@"\n  -%@\n", selName];
            [log appendString:block];
        } else {
            [log appendFormat:@"\n  -%@ : (no probe class owns this)\n", selName];
        }
    }
}

// Call one getter on `target` and render its value as a report line. Handles
// the scalar/integer encodings plus object returns (printing an array's count
// and a trimmed description). Anything else is reported as unhandled rather
// than guessed at -- a wrong objc_msgSend signature here would crash.
static NSString *WXKBT_DescribeGetter(id target, NSString *name, SEL sel, const char *enc) {
    if (target == nil || sel == NULL || enc == NULL) return @"";
    char r = enc[0];
    @try {
        if (r == 'q') {
            long long v = ((long long (*)(id, SEL))objc_msgSend)(target, sel);
            return [NSString stringWithFormat:@"      -%@ = %lld\n", name, v];
        }
        if (r == 'Q') {
            unsigned long long v = ((unsigned long long (*)(id, SEL))objc_msgSend)(target, sel);
            return [NSString stringWithFormat:@"      -%@ = %llu\n", name, v];
        }
        if (r == 'i') {
            int v = ((int (*)(id, SEL))objc_msgSend)(target, sel);
            return [NSString stringWithFormat:@"      -%@ = %d\n", name, v];
        }
        if (r == 'I') {
            unsigned v = ((unsigned (*)(id, SEL))objc_msgSend)(target, sel);
            return [NSString stringWithFormat:@"      -%@ = %u\n", name, v];
        }
        if (r == 'l') {
            long v = ((long (*)(id, SEL))objc_msgSend)(target, sel);
            return [NSString stringWithFormat:@"      -%@ = %ld\n", name, v];
        }
        if (r == 'B' || r == 'c') {
            BOOL v = ((BOOL (*)(id, SEL))objc_msgSend)(target, sel);
            return [NSString stringWithFormat:@"      -%@ = %s\n", name, v ? "YES" : "NO"];
        }
        if (r == '@') {
            id v = ((id (*)(id, SEL))objc_msgSend)(target, sel);
            NSUInteger n = 0;
            if ([v isKindOfClass:[NSArray class]] || [v isKindOfClass:[NSSet class]] ||
                [v isKindOfClass:[NSDictionary class]]) {
                n = (NSUInteger)[v count];
            }
            return [NSString stringWithFormat:@"      -%@ = <%s> count=%lu  %@\n", name,
                (v != nil) ? class_getName(object_getClass(v)) : "nil",
                (unsigned long)n, WXKBT_Trim(v, 300)];
        }
        return [NSString stringWithFormat:@"      -%@ = (unhandled enc %s)\n", name, enc];
    } @catch (__unused NSException *e) {
        return [NSString stringWithFormat:@"      -%@ threw\n", name];
    }
}

// Force an object out of a getter and print its real value. This is the part
// that actually answers "which number is the 7".
static void WXKBT_ReportLiveValues(NSMutableString *log,
                                   NSArray<NSString *> *classNames,
                                   NSArray<NSString *> *getters) {
    [log appendString:@"\n=== live getter values (CALLED, not just named) ===\n"];
    [log appendString:@"  Only instance getters returning a scalar or object are called.\n"];

    // Names of shared-instance accessors this codebase actually uses. We do
    // NOT fall back to -alloc/-init: instantiating an arbitrary class here
    // (especially a UIView subclass) can run real setup work and is exactly
    // the kind of perturbation this build exists to avoid. If a class does
    // not expose a shared instance, we say so and move on.
    NSArray<NSString *> *sharedSelNames = @[
        @"sharedInstance", @"sharedPreferences", @"sharedManager",
        @"shared", @"defaultInstance", @"getInstance",
    ];

    for (NSString *cn in classNames) {
        Class cls = objc_getClass(cn.UTF8String);
        if (cls == Nil) continue;

        id inst = nil;
        NSString *via = nil;
        for (NSString *sn in sharedSelNames) {
            SEL s = NSSelectorFromString(sn);
            if (s == NULL || ![cls respondsToSelector:s]) continue;
            @try {
                id got = ((id (*)(id, SEL))objc_msgSend)(cls, s);
                if (got != nil) { inst = got; via = sn; }
            } @catch (__unused NSException *e) {
                inst = nil;
            }
            if (inst != nil) break;
        }
        if (inst == nil) {
            [log appendFormat:@"\n  [%@] no shared instance (-%@ etc.) -- skipped\n",
                cn, sharedSelNames.firstObject];
            continue;
        }

        BOOL printedHeader = NO;
        for (NSString *g in getters) {
            SEL sel = NSSelectorFromString(g);
            if (sel == NULL || ![inst respondsToSelector:sel]) continue;
            Method m = class_getInstanceMethod(object_getClass(inst), sel);
            if (m == NULL) m = class_getInstanceMethod(cls, sel);
            if (m == NULL) continue;
            const char *enc = method_getTypeEncoding(m);
            if (enc == NULL) continue;

            if (!printedHeader) {
                [log appendFormat:@"\n  [%@] via -%@  (instance %s)\n", cn, via,
                    class_getName(object_getClass(inst))];
                printedHeader = YES;
            }
            [log appendString:WXKBT_DescribeGetter(inst, g, sel, enc)];
        }
        if (!printedHeader) {
            [log appendFormat:@"\n  [%@] instance ok, none of the getters present\n", cn];
        }

        // Class-level getters too: some preferences classes expose the cap as
        // a +method rather than through an instance.
        for (NSString *g in getters) {
            SEL sel = NSSelectorFromString(g);
            if (sel == NULL || ![cls respondsToSelector:sel]) continue;
            Method m = class_getClassMethod(cls, sel);
            if (m == NULL) continue;
            const char *enc = method_getTypeEncoding(m);
            if (enc == NULL) continue;
            [log appendFormat:@"\n  [%@] via +%@  (class method)\n", cn, g];
            [log appendString:WXKBT_DescribeGetter(cls, g, sel, enc)];
        }
    }
}

// Full method + ivar dump of one class. Used on WBToolbarPreferences, whose
// ivars are the most likely place for a literal cap constant.
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
    [log appendFormat:@"  own instance methods: %u\n", mc];
    for (unsigned int i = 0; i < mc; i++) {
        const char *nm = sel_getName(method_getName(ms[i]));
        const char *le = method_getTypeEncoding(ms[i]);
        // Print everything that could plausibly carry a count or a list.
        if (WXKBT_NameHas(nm, "toolbar") || WXKBT_NameHas(nm, "func") ||
            WXKBT_NameHas(nm, "count") || WXKBT_NameHas(nm, "limit") ||
            WXKBT_NameHas(nm, "enabled") || WXKBT_NameHas(nm, "list") ||
            WXKBT_NameHas(nm, "max") || WXKBT_NameHas(nm, "order") ||
            WXKBT_NameHas(nm, "item") || WXKBT_NameHas(nm, "scene") ||
            WXKBT_NameHas(nm, "config") || WXKBT_NameHas(nm, "save") ||
            WXKBT_NameHas(nm, "load")) {
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
        [log appendFormat:@"    %s  [%s]\n", (nm != NULL) ? nm : "?",
            (te != NULL) ? te : "?"];
    }
    free(ivs);
}

// Files + app-group defaults that could carry the list across processes.
static void WXKBT_ReportSharedState(NSMutableString *log) {
    [log appendString:@"\n=== shared state inventory ===\n"];

    NSUserDefaults *std = [NSUserDefaults standardUserDefaults];
    NSDictionary *all = [std dictionaryRepresentation];
    [log appendFormat:@"  standardUserDefaults keys: %lu\n", (unsigned long)all.count];
    NSUInteger hits = 0;
    for (NSString *k in all) {
        if (WXKBT_NameHas(k.UTF8String, "toolbar") || WXKBT_NameHas(k.UTF8String, "func") ||
            WXKBT_NameHas(k.UTF8String, "panel") || WXKBT_NameHas(k.UTF8String, "count")) {
            [log appendFormat:@"    KEY %@ = %@\n", k, WXKBT_Trim(all[k], 300)];
            hits++;
        }
    }
    [log appendFormat:@"    (related keys: %lu)\n", (unsigned long)hits];

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
            if (WXKBT_NameHas(k.UTF8String, "toolbar") || WXKBT_NameHas(k.UTF8String, "func") ||
                WXKBT_NameHas(k.UTF8String, "panel") || WXKBT_NameHas(k.UTF8String, "order")) {
                [log appendFormat:@"    KEY %@ = %@\n", k, WXKBT_Trim(gdAll[k], 400)];
            }
        }
    }

    NSString *home = NSHomeDirectory();
    [log appendFormat:@"  container: %s\n", WXKBT_CStr(home)];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *subdirs = @[@"Documents", @"Library/Preferences",
                                     @"Library/Application Support", @"Library/Caches"];
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

#pragma mark - On-screen delivery (v0.8.0)

// Build a SHORT, human-readable summary. The user will read this off a
// screenshot, so it must fit on a phone screen and lead with the answer.
// Full detail still goes to the file/syslog path.
static NSString *WXKBT_BuildScreenText(NSString *fullLog,
                                       NSArray<NSString *> *classes,
                                       NSArray<NSString *> *sels,
                                       NSArray<NSString *> *getters,
                                       NSString *role) {
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"角色: %@  (%@)\n\n", role,
        [role isEqualToString:@"kbd"] ? @"键盘扩展" : @"宿主App"];

    // --- 1. Which classes exist here ---
    NSMutableArray<NSString *> *present = [NSMutableArray array];
    for (NSString *cn in classes) {
        if (objc_getClass(cn.UTF8String) != Nil) [present addObject:cn];
    }
    [s appendFormat:@"【存在的关键类 %lu 个】\n", (unsigned long)present.count];
    for (NSString *cn in present) [s appendFormat:@"  %@\n", cn];
    [s appendString:@"\n"];

    // --- 2. Who owns the cap selectors ---
    [s appendString:@"【关键方法归属】\n"];
    NSArray<NSString *> *keySels = @[@"setToolbarFuncs:", @"toolbarFuncs",
                                     @"maxCount", @"countLimit",
                                     @"itemCount", @"configItemCount",
                                     @"canSetToolbarFunc:enabled:"];
    for (NSString *selName in keySels) {
        SEL sel = NSSelectorFromString(selName);
        if (sel == NULL) continue;
        NSMutableArray<NSString *> *owners = [NSMutableArray array];
        for (NSString *cn in classes) {
            Class c = objc_getClass(cn.UTF8String);
            if (c != Nil && WXKBT_OwnsSelector(c, sel)) [owners addObject:cn];
        }
        if (owners.count == 0) {
            [s appendFormat:@"  %@  -> (无)\n", selName];
        } else {
            [s appendFormat:@"  %@  -> %@\n", selName,
                [owners componentsJoinedByString:@", "]];
        }
    }
    [s appendString:@"\n"];

    // --- 3. Live numeric values (the actual answer) ---
    [s appendString:@"【实测数值】\n"];
    BOOL anyNum = NO;
    for (NSString *cn in @[@"WBToolbarPreferences", @"WBPanelConfig",
                           @"WBFunctionToolBar", @"WBCustomToolBarView"]) {
        Class cls = objc_getClass(cn.UTF8String);
        if (cls == Nil) continue;
        id inst = nil;
        for (NSString *sn in @[@"sharedInstance", @"sharedPreferences", @"sharedManager"]) {
            SEL sh = NSSelectorFromString(sn);
            if (sh != NULL && [cls respondsToSelector:sh]) {
                inst = ((id (*)(id, SEL))objc_msgSend)(cls, sh);
                if (inst != nil) break;
            }
        }
        if (inst == nil) continue;
        for (NSString *g in getters) {
            SEL sel = NSSelectorFromString(g);
            if (sel == NULL || ![inst respondsToSelector:sel]) continue;
            Method m = class_getInstanceMethod(object_getClass(inst), sel);
            if (m == NULL) m = class_getInstanceMethod(cls, sel);
            if (m == NULL) continue;
            const char *enc = method_getTypeEncoding(m);
            if (enc == NULL) continue;
            char r = enc[0];
            @try {
                if (r == 'q' || r == 'l') {
                    long long v = ((long long (*)(id, SEL))objc_msgSend)(inst, sel);
                    [s appendFormat:@"  %@.%@ = %lld\n", cn, g, v]; anyNum = YES;
                } else if (r == 'Q' || r == 'I') {
                    unsigned long long v = ((unsigned long long (*)(id, SEL))objc_msgSend)(inst, sel);
                    [s appendFormat:@"  %@.%@ = %llu\n", cn, g, v]; anyNum = YES;
                } else if (r == 'i') {
                    int v = ((int (*)(id, SEL))objc_msgSend)(inst, sel);
                    [s appendFormat:@"  %@.%@ = %d\n", cn, g, v]; anyNum = YES;
                } else if (r == '@') {
                    id v = ((id (*)(id, SEL))objc_msgSend)(inst, sel);
                    NSUInteger n = 0;
                    if ([v isKindOfClass:[NSArray class]]) n = (NSUInteger)[v count];
                    [s appendFormat:@"  %@.%@ = %lu 个\n", cn, g, (unsigned long)n];
                    anyNum = YES;
                }
            } @catch (__unused NSException *e) {
                [s appendFormat:@"  %@.%@ = (异常)\n", cn, g];
            }
        }
    }
    if (!anyNum) [s appendString:@"  (取不到实例，见完整日志)\n"];

    return s;
}

// Tiny helper whose only job is to close the on-keyboard panel. Declared as a
// real class so the button has a stable target.
@interface WXKBT_Closer : NSObject
@property (nonatomic, weak) UIView *panelView;
@property (nonatomic, weak) UIViewController *panelVC;
+ (instancetype)shared;
- (void)tap:(id)sender;
@end

@implementation WXKBT_Closer
+ (instancetype)shared {
    static WXKBT_Closer *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[WXKBT_Closer alloc] init]; });
    return s;
}
- (void)tap:(id)sender {
    UIViewController *vc = self.panelVC;
    UIView *v = self.panelView;
    [vc dismissViewControllerAnimated:YES completion:nil];
    [v removeFromSuperview];
    self.panelVC = nil;
    self.panelView = nil;
}
@end

// Keyboard-extension side: present the report INSIDE the keyboard process.
//
// A keyboard extension cannot use UIApplication the way an app does, but it
// does have its own window and a view controller chain. We find the topmost
// view controller among all the extension's windows and present from there.
// If presentation is refused for any reason, we fall back to attaching the
// text view directly to the keyboard's own root view, which always works.
static void WXKBT_PresentInKeyboard(NSString *text) {
    if (text.length == 0) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        // 1. Collect every window we can see in this process.
        NSMutableArray<UIWindow *> *wins = [NSMutableArray array];
        if (@available(iOS 13.0, *)) {
            for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
                if (![sc isKindOfClass:[UIWindowScene class]]) continue;
                for (UIWindow *w in ((UIWindowScene *)sc).windows) [wins addObject:w];
            }
        }
        if (wins.count == 0) {
            for (UIWindow *w in [UIApplication sharedApplication].windows) [wins addObject:w];
        }
        // Pick the largest window -- for a keyboard that is the keyboard one.
        UIWindow *host = nil;
        CGFloat best = 0;
        for (UIWindow *w in wins) {
            CGFloat area = w.bounds.size.width * w.bounds.size.height;
            if (area > best) { best = area; host = w; }
        }
        if (host == nil) return;

        // 2. Build the panel.
        UIViewController *vc = [[UIViewController alloc] init];
        vc.view.backgroundColor = [UIColor systemBackgroundColor];

        UITextView *tv = [[UITextView alloc] initWithFrame:vc.view.bounds];
        tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        tv.editable = NO;
        tv.font = [UIFont fontWithName:@"Menlo" size:11] ?: [UIFont systemFontOfSize:11];
        tv.text = text;
        [vc.view addSubview:tv];

        // A close button, because a keyboard has no nav bar to dismiss with.
        // It removes the panel whichever path attached it, by trying the
        // modal dismissal and then falling back to removing the subview.
        UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
        close.frame = CGRectMake(vc.view.bounds.size.width - 76, 8, 68, 34);
        close.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
        [close setTitle:@"关闭" forState:UIControlStateNormal];
        [close addTarget:[WXKBT_Closer shared] action:@selector(tap:)
        forControlEvents:UIControlEventTouchUpInside];
        [WXKBT_Closer shared].panelView = vc.view;
        [WXKBT_Closer shared].panelVC  = vc;
        [vc.view addSubview:close];

        // 3. Try a normal modal presentation first.
        UIViewController *top = host.rootViewController;
        while (top.presentedViewController != nil) top = top.presentedViewController;
        if (top != nil) {
            vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
            @try {
                [top presentViewController:vc animated:YES completion:nil];
                return;
            } @catch (__unused NSException *e) {
                // fall through to the direct-attach path
            }
        }

        // 4. Fallback: attach straight onto the keyboard's root view. This
        //    bypasses all presentation machinery, so it cannot be refused.
        UIView *rootView = host.rootViewController.view ?: host;
        vc.view.frame = rootView.bounds;
        vc.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [rootView addSubview:vc.view];
    });
}

// Keyboard-extension side: stash the summary where the host app can read it.
// Both processes can reach the shared pref domain, and it needs no file
// permission at all.
static void WXKBT_SaveForHost(NSString *text) {
    if (text.length == 0) return;
    NSUserDefaults *d = WXKBT_Prefs();
    if (d == nil) return;
    [d setObject:text forKey:@"KbdReport"];
    [d setObject:[NSDate date] forKey:@"KbdReportDate"];
    [d synchronize];
}

// Host-app side: show the keyboard's findings (if any) plus our own, in an
// alert the user can screenshot. Runs on the main thread.
static void WXKBT_PresentOnScreen(NSString *hostText, NSString *role) {
    // Pull what the keyboard saved earlier.
    NSUserDefaults *d = WXKBT_Prefs();
    NSString *kbdText = [d stringForKey:@"KbdReport"];
    NSLog(@"[WXKBT+] presenting on screen. kbdReport=%@", kbdText ? @"yes" : @"none");

    NSMutableString *body = [NSMutableString string];
    if (kbdText.length > 0) {
        [body appendString:@"======== 键盘进程报告 ========\n"];
        [body appendString:kbdText];
        [body appendString:@"\n\n======== 宿主App报告 ========\n"];
    } else {
        [body appendString:@"(还没收到键盘进程的报告；请先调出微信输入法键盘打几个字)\n\n"];
    }
    [body appendString:hostText];

    // The app may not have a window yet at 3s, so retry a few times.
    for (int attempt = 0; attempt < 20; attempt++) {
        __block BOOL done = NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            UIWindow *win = nil;
            for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
                if (![sc isKindOfClass:[UIWindowScene class]]) continue;
                for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                    if (w.isKeyWindow) { win = w; break; }
                }
                if (win == nil) win = ((UIWindowScene *)sc).windows.firstObject;
                if (win != nil) break;
            }
            UIViewController *root = win.rootViewController;
            if (root == nil) return;

            // Do not stack up multiple copies if this runs twice.
            if ([root.presentedViewController isKindOfClass:[UINavigationController class]] &&
                [[(UINavigationController *)root.presentedViewController topViewController].title
                    hasPrefix:@"wxkbt+"]) {
                done = YES;
                return;
            }

            UIViewController *vc = [[UIViewController alloc] init];
            vc.title = [NSString stringWithFormat:@"wxkbt+ %@", kBuildTag];
            vc.view.backgroundColor = [UIColor systemBackgroundColor];

            UITextView *tv = [[UITextView alloc] initWithFrame:vc.view.bounds];
            tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            tv.editable = NO;
            tv.font = [UIFont fontWithName:@"Menlo" size:10] ?: [UIFont systemFontOfSize:10];
            tv.text = body;
            [vc.view addSubview:tv];

            UINavigationController *nav =
                [[UINavigationController alloc] initWithRootViewController:vc];
            nav.modalPresentationStyle = UIModalPresentationPageSheet;
            vc.navigationItem.rightBarButtonItem =
                [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                              target:nav
                                                              action:@selector(dismissViewControllerAnimated:completion:)];

            UIViewController *top = root;
            while (top.presentedViewController != nil) top = top.presentedViewController;
            [top presentViewController:nav animated:YES completion:nil];
            done = YES;
        });
        // Give the main queue a moment, then check whether we succeeded.
        [NSThread sleepForTimeInterval:0.5];
        if (done) break;
    }
}

#pragma mark - Worker thread

static void *WXKBT_Worker(void *arg) {
    (void)arg;
    @autoreleasepool {
        NSString *bid  = [[NSBundle mainBundle] bundleIdentifier];
        NSString *exec = [[NSBundle mainBundle] executablePath];
        if (bid == nil)  bid = @"";
        if (exec == nil) exec = @"";
        BOOL isKeyboardExt = [bid hasSuffix:@".keyboard"] ||
                             [exec rangeOfString:@"wxkb_plugin"].location != NSNotFound;
        NSString *role = isKeyboardExt ? @"kbd" : @"app";

        // Wait until the keyboard has drawn. Doing this at launch would put the
        // scan on the same runloop tick as first layout.
        sleep(3);

        NSMutableString *log = [NSMutableString string];
        [log appendString:@"# wxkbt+ RUNTIME DIAGNOSTIC (v0.8.1 - KEYBOARD SELF-PRESENTS)\n"];
        [log appendFormat:@"build=%s\n", WXKBT_CStr(kBuildTag)];
        [log appendFormat:@"bundle=%s\n", WXKBT_CStr(bid)];
        [log appendFormat:@"exec=%s\n", WXKBT_CStr(exec)];
        [log appendFormat:@"role=%s\n", isKeyboardExt ? "KEYBOARD EXTENSION" : "host app"];
        [log appendFormat:@"home=%s\n", WXKBT_CStr(NSHomeDirectory())];
        [log appendString:
            @"hooked=NONE        (this build replaces zero methods)\n"
            @"classListWalk=NO   (objc_copyClassList is never called)\n"
            @"pid="];
        [log appendFormat:@"%d\n", (int)getpid()];

        BOOL isWeType = [bid hasPrefix:@"com.tencent.wetype"] ||
                        [exec rangeOfString:@"wxkb"].location != NSNotFound;
        if (!isWeType) {
            [log appendString:@"not WeType -- nothing to do\n"];
            WXKBT_WriteStatusForRole(role, log);
            return NULL;
        }

        if (!WXKBT_BoolDefaultYes(kPrefEnabled)) {
            [log appendString:@"master switch = OFF\n"];
            WXKBT_WriteStatusForRole(role, log);
            return NULL;
        }

        NSArray<NSString *> *classes = WXKBT_ProbeClasses();
        NSArray<NSString *> *sels    = WXKBT_ProbeSelectors();
        NSArray<NSString *> *getters = WXKBT_CallableGetters();

        WXKBT_ReportCensus(log, classes);
        WXKBT_ReportSelectorOwners(log, classes, sels);

        // The part that matters: read actual numbers out of the live objects.
        WXKBT_ReportLiveValues(log, classes, getters);

        // Cap-carrying classes get a full dump so we can see literal constants.
        [log appendString:@"\n=== full detail of cap-carrying classes ===\n"];
        for (NSString *cn in @[@"WBToolbarPreferences", @"WBPanelConfig",
                               @"WBFunctionToolBar", @"WBCustomToolBarView"]) {
            WXKBT_ReportClassDetail(log, cn);
        }

        WXKBT_ReportSharedState(log);

        [log appendString:
            @"\n=== how to read this ===\n"
            @"1. Under 'live getter values', find any count that equals 7 (or a\n"
            @"   number just above the visible button count). That is the cap.\n"
            @"2. Under 'selector ownership', note the real class owning\n"
            @"   setToolbarFuncs: / toolbarFuncs -- that is the write path.\n"
            @"3. Under 'full detail of cap-carrying classes', look for an ivar\n"
            @"   whose name suggests a count and a nearby literal constant.\n"
            @"4. Send the whole file back; the fix will hook ONLY whichever one\n"
            @"   of the above actually carries the 7.\n"];

        if (WXKBT_BoolDefaultYes(kPrefVerbose)) {
            [log appendString:@"\n=== verbose: detail of every probe class ===\n"];
            for (NSString *cn in classes) { WXKBT_ReportClassDetail(log, cn); }
        }

        // Write last, and record where it landed, so the file itself tells you
        // every path it was saved to.
        NSMutableString *footer = [NSMutableString string];
        [footer appendString:@"\n=== where this report was written ===\n"];
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *dir in WXKBT_OutputDirs()) {
            if (dir.length == 0) continue;
            NSArray<NSString *> *names = @[
                @"wxkbt-status.txt",
                [NSString stringWithFormat:@"wxkbt-status-%@.txt", role],
            ];
            for (NSString *n in names) {
                NSString *p = [dir stringByAppendingPathComponent:n];
                if ([fm fileExistsAtPath:p]) [footer appendFormat:@"    %@\n", p];
            }
        }
        [footer appendString:
            @"\n  NOTE: an app-group path looks like\n"
            @"  /var/mobile/Containers/Shared/AppGroup/<UUID>/wxkbt-status-kbd.txt\n"
            @"  and is reachable in Filza without knowing any per-app UUID.\n"];
        [log appendString:footer];

        // ============================================================
        // DELIVERY, take 4: THE KEYBOARD PRESENTS ITSELF.
        // ============================================================
        // Takes 1-3 all tried to move the keyboard's findings somewhere else
        // (files, syslog, shared prefs) and every one failed, because a
        // sandboxed extension cannot write a path the host app can read and
        // the two processes' NSUserDefaults suites are separate when the name
        // is not a declared app group.
        //
        // The answer is to stop moving the data at all. A keyboard extension
        // IS allowed to present a view controller inside its own process --
        // that is how keyboards show their own popups. So we present the
        // report right here, on top of the keyboard. Nothing crosses a
        // process boundary, so nothing can fail.
        //
        // The host app keeps its own presentation as a secondary path.
        NSString *screen = WXKBT_BuildScreenText(log, classes, sels, getters, role);

        WXKBT_WriteStatusForRole(role, log);
        NSLog(@"[WXKBT+] %@ diag done (role=%@)", kBuildTag, role);

        if (isKeyboardExt) {
            // Present inside the keyboard's own window.
            WXKBT_PresentInKeyboard(screen);
            // Also stash a copy in case the host app route works.
            WXKBT_SaveForHost(screen);
        } else {
            WXKBT_PresentOnScreen(screen, role);
        }
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
