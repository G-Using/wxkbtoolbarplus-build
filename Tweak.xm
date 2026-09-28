// WXKeyboardToolbarPlus
// Theos + Logos tweak for WeType (微信输入法) keyboard.
//
// Ground truth established from the on-device binary dump (wxkb.app):
//   App          : /var/containers/Bundle/Application/<UUID>/wxkb.app
//                  bundle = com.tencent.wetype        exec = wxkb
//   Keyboard ext : wxkb.app/PlugIns/wxkb_plugin.appex
//                  bundle = com.tencent.wetype.keyboard  exec = wxkb_plugin
//   Real classes : WBFunctionToolBar, WBCustomToolBarView, WBToolBarButton,
//                  WBCombinedToolBarButton, WBTranslateViewToolBar,
//                  WBToolBarAuxiliary, WBCCFuncItem, WBCoreStackView
//   Protocols    : WBCustomToolBarEditingProtocol, WBCustomToolBarScrolViewDelegate
//
// Because the concrete class that owns the toolbar layout can still change
// between WeType releases, ALL hooks here are installed dynamically at runtime
// (class enumeration + method_setImplementation) instead of Logos %hook on a
// guessed name. If WeType renames something we degrade gracefully instead of
// silently doing nothing.
//
// Hard rules:
//   - Never recreate buttons. We only reparent existing UIControls into a
//     UIScrollView with their frames preserved: icons, target/action chains and
//     hit-testing stay byte-identical to the originals.
//   - Never swizzle global UIKit methods (UIView/+load/+initialize). We only
//     touch concrete WeType classes, so a liquid-glass keyboard beautifier
//     tweak keeps working.
//   - Never hardcode jailbreak root paths. Writes go through NSHomeDirectory()
//     first (always writable inside a sandbox), then the legacy rootless paths.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <sys/sysctl.h>
#import <sys/types.h>
#import <mach-o/loader.h>
#import <mach-o/fat.h>
#import <mach/machine.h>
#import <dispatch/dispatch.h>
#import <string.h>
#import <stdlib.h>
#import <unistd.h>

#pragma mark - Preference keys

static NSString * const kPrefDomain        = @"com.gusing.wxkbtoolbarplus";
static NSString * const kPrefEnabled       = @"Enabled";          // BOOL master
static NSString * const kPrefHidePanel     = @"HidePanel";        // BOOL
static NSString * const kPrefHideVoice     = @"HideVoice";        // BOOL
static NSString * const kPrefHideEmoji     = @"HideEmoji";        // BOOL
static NSString * const kPrefHideAI        = @"HideAI";           // BOOL
static NSString * const kPrefHideSimplify  = @"HideSimplify";     // BOOL
static NSString * const kPrefHideKeyboard  = @"HideKeyboard";     // BOOL

#pragma mark - Associated objects

static const void *kScrollContainerKey = &kScrollContainerKey;
static const NSInteger kScrollViewTag  = 0x5758BEEF;

// ---------------------------------------------------------------------------
// Diagnostic plumbing
//
// IMPORTANT: a process under RootHide/rootless that is NOT SpringBoard runs
// inside the app sandbox. /var/mobile/Documents and /tmp are usually blocked
// there, which is why the previous builds looked like "the tweak never loaded"
// even when it actually did. So the FIRST target is always
// NSHomeDirectory()/Documents — the one directory every sandbox can write.
// SpringBoard then relays what it finds into /var/mobile/Documents so the user
// only has to look in one place.
// ---------------------------------------------------------------------------

static NSArray<NSString *> *WXKBT_WriteDirs(void) {
    NSMutableArray<NSString *> *dirs = [NSMutableArray array];
    NSString *home = NSHomeDirectory();
    if (home.length > 0) {
        [dirs addObject:[home stringByAppendingPathComponent:@"Documents"]];
        [dirs addObject:home];
    }
    [dirs addObject:@"/var/mobile/Documents"];
    [dirs addObject:@"/tmp"];
    return dirs;
}

static BOOL WXKBT_WriteToAllLocations(NSString *basename, NSString *body) {
    BOOL anyOK = NO;
    for (NSString *dir in WXKBT_WriteDirs()) {
        BOOL isDir = NO;
        if (![[NSFileManager defaultManager] fileExistsAtPath:dir isDirectory:&isDir] || !isDir) {
            continue;
        }
        NSString *path = [dir stringByAppendingPathComponent:basename];
        NSError *err = nil;
        BOOL ok = [body writeToFile:path atomically:YES
                           encoding:NSUTF8StringEncoding
                              error:&err];
        if (ok) anyOK = YES;
    }
    return anyOK;
}

static void WXKBT_WriteBootInfo(const char *status) {
    NSMutableString *info = [NSMutableString string];
    [info appendFormat:@"pid=%d\n", getpid()];
    [info appendFormat:@"status=%s\n", status];
    [info appendFormat:@"main_bundle=%s\n", [[[NSBundle mainBundle] bundleIdentifier] UTF8String] ?: "nil"];
    [info appendFormat:@"main_exec=%s\n", [[[NSBundle mainBundle] executablePath] UTF8String] ?: "nil"];
    [info appendFormat:@"home=%s\n", [NSHomeDirectory() UTF8String] ?: "nil"];
    [info appendFormat:@"write_dir=%s\n", [[[WXKBT_WriteDirs() firstObject] ?: @"?" description] UTF8String] ?: "nil"];
    NSString *basename = [NSString stringWithFormat:@"wxkbt-info-%d.txt", getpid()];
    WXKBT_WriteToAllLocations(basename, info);
}

// ---------------------------------------------------------------------------
// SpringBoard relay
//
// SpringBoard is always injected (it is in the filter) and it is NOT
// sandboxed, so it can read every app / extension container. A low-frequency
// timer copies any wxkbt-*.txt it finds inside those containers into
// /var/mobile/Documents/relay-*.txt, which is where the user looks.
// ---------------------------------------------------------------------------

static void WXKBT_RelayOnce(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dest = @"/var/mobile/Documents";
    BOOL destOK = NO;
    if (![fm fileExistsAtPath:dest isDirectory:&destOK] || !destOK) return;

    NSArray<NSString *> *roots = @[
        @"/var/mobile/Containers/Data/Application",
        @"/var/mobile/Containers/Data/PluginKitPlugin",
    ];
    NSArray<NSString *> *subs = @[@"Documents", @"tmp", @"Library/Caches", @""];
    NSUInteger copied = 0;

    for (NSString *root in roots) {
        for (NSString *uuid in [fm contentsOfDirectoryAtPath:root error:NULL] ?: @[]) {
            NSString *container = [root stringByAppendingPathComponent:uuid];
            for (NSString *sub in subs) {
                NSString *dir = sub.length ? [container stringByAppendingPathComponent:sub] : container;
                for (NSString *f in [fm contentsOfDirectoryAtPath:dir error:NULL] ?: @[]) {
                    if (![f hasPrefix:@"wxkbt-"] && ![f hasPrefix:@"relay-"]) continue;
                    if (![f hasSuffix:@".txt"]) continue;
                    NSString *src = [dir stringByAppendingPathComponent:f];
                    NSString *shortID = uuid.length > 8 ? [uuid substringToIndex:8] : uuid;
                    NSString *outName = [NSString stringWithFormat:@"relay-%@-%@", shortID, f];
                    NSString *dst = [dest stringByAppendingPathComponent:outName];
                    [fm removeItemAtPath:dst error:NULL];
                    if ([fm copyItemAtPath:src toPath:dst error:NULL]) copied++;
                }
            }
        }
    }

    NSString *stamp = [NSString stringWithFormat:
        @"relay run at %@\npid=%d\ncopied=%lu\n",
        [NSDate date], getpid(), (unsigned long)copied];
    [stamp writeToFile:[dest stringByAppendingPathComponent:@"relay-status.txt"]
            atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

static void WXKBT_StartSpringBoardRelay(void) {
    static dispatch_source_t timer = NULL;
    if (timer != NULL) return;

    WXKBT_RelayOnce();

    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0));
    if (timer == NULL) return;
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, 15ull * NSEC_PER_SEC),
                              15ull * NSEC_PER_SEC,
                              5ull * NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{
        @autoreleasepool { WXKBT_RelayOnce(); }
    });
    dispatch_resume(timer);
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

#pragma mark - Core: make a toolbar row horizontally scrollable

static NSString *WXKBT_ClassNameOf(id obj);

// WeType does not necessarily put the tool buttons directly inside
// WBFunctionToolBar — there may be an intermediate WBCoreStackView / plain
// UIView. So instead of guessing, walk down (max `depth` levels) and take the
// first descendant that holds at least two direct UIControl children: that is
// the actual button row.
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

        // Move the buttons. Frame preserved, so icons / target-action / hit
        // testing stay byte-identical to the originals.
        for (UIView *btn in controls) {
            CGRect f = btn.frame;
            [btn removeFromSuperview];
            btn.frame = f;
            [scroll addSubview:btn];
        }
        NSLog(@"[WXKBT+] wrapped %@ with %lu buttons into a scroll view",
              WXKBT_ClassNameOf(row), (unsigned long)controls.count);
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

    // Visibility switches from PreferenceLoader
    NSUserDefaults *def = [NSUserDefaults standardUserDefaults];
    BOOL master = [def boolForKey:kPrefEnabled];
    NSDictionary<NSString *, NSArray<NSString *> *> *keywordMap = WXKBT_KeywordMap();

    NSMutableArray<NSString *> *activeKeys = [NSMutableArray array];
    if (master) {
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

static NSMutableDictionary<NSString *, NSValue *> *gOrigLayoutIMPs = nil;
static NSMutableSet<NSString *> *gHookedClasses = nil;

static NSString *WXKBT_ClassNameOf(id obj) {
    const char *cn = class_getName(object_getClass(obj));
    return (cn != NULL) ? [NSString stringWithUTF8String:cn] : @"?";
}

static void WXKBT_layoutSubviews_hook(id self, SEL _cmd) {
    NSString *cn = WXKBT_ClassNameOf(self);
    NSValue *v = gOrigLayoutIMPs[cn];
    if (v != nil) {
        void (*orig)(id, SEL) = (void (*)(id, SEL))[v pointerValue];
        if (orig != NULL) orig(self, _cmd);
    } else {
        // Fallback: call the implementation we replaced, looked up on the
        // superclass (our own method now shadows it).
        Class sup = class_getSuperclass(object_getClass(self));
        if (sup != Nil) {
            IMP imp = class_getMethodImplementation(sup, _cmd);
            if (imp != NULL) ((void (*)(id, SEL))imp)(self, _cmd);
        }
    }
    @autoreleasepool {
        WXKBT_WrapInScrollView((UIView *)self);
    }
}

static BOOL WXKBT_NameLooksLikeToolBar(NSString *name) {
    if (name.length == 0) return NO;
    NSString *n = [name lowercaseString];
    if ([n rangeOfString:@"toolbar"].location != NSNotFound) return YES;
    if ([n rangeOfString:@"tool bar"].location != NSNotFound) return YES;
    if ([n rangeOfString:@"funcbar"].location != NSNotFound) return YES;
    if ([n rangeOfString:@"funcbarview"].location != NSNotFound) return YES;
    return NO;
}

static void WXKBT_HookToolbarLayouts(void) {
    if (gOrigLayoutIMPs == nil) gOrigLayoutIMPs = [NSMutableDictionary dictionary];
    if (gHookedClasses == nil) gHookedClasses = [NSMutableSet set];

    SEL sel = @selector(layoutSubviews);
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (classes == NULL) return;

    NSUInteger hooked = 0;
    for (unsigned int i = 0; i < count; i++) {
        Class cls = classes[i];
        const char *cname = class_getName(cls);
        if (cname == NULL) continue;
        NSString *name = [NSString stringWithUTF8String:cname];
        if (!WXKBT_NameLooksLikeToolBar(name)) continue;
        if ([gHookedClasses containsObject:name]) continue;

        // Must actually be a UIView (has subviews) and must *own* layoutSubviews.
        Class walker = cls;
        BOOL isView = NO;
        while (walker != Nil && walker != [NSObject class]) {
            if (walker == [UIView class]) { isView = YES; break; }
            walker = class_getSuperclass(walker);
        }
        if (!isView) continue;
        if ([cls isSubclassOfClass:[UIControl class]]) continue;   // it's a button

        unsigned int mc = 0;
        Method *ms = class_copyMethodList(cls, &mc);
        BOOL owns = NO;
        for (unsigned int j = 0; j < mc; j++) {
            if (method_getName(ms[j]) == sel) { owns = YES; break; }
        }
        free(ms);
        if (!owns) continue;

        Method m = class_getInstanceMethod(cls, sel);
        if (m == NULL) continue;
        IMP orig = method_getImplementation(m);
        gOrigLayoutIMPs[name] = [NSValue valueWithPointer:(void *)orig];
        method_setImplementation(m, (IMP)WXKBT_layoutSubviews_hook);
        [gHookedClasses addObject:name];
        hooked++;
        NSLog(@"[WXKBT+] hooked -[%@ layoutSubviews]", name);
    }
    free(classes);

    NSLog(@"[WXKBT+] toolbar layout hooks installed: %lu", (unsigned long)hooked);
    if (hooked == 0) {
        NSMutableString *out = [NSMutableString string];
        [out appendFormat:@"# no toolbar-like UIView owned layoutSubviews\n"];
        [out appendFormat:@"bundle=%s\n", [[[NSBundle mainBundle] bundleIdentifier] UTF8String] ?: "nil"];
        [out appendFormat:@"exec=%s\n", [[[NSBundle mainBundle] executablePath] UTF8String] ?: "nil"];
        WXKBT_WriteToAllLocations([NSString stringWithFormat:@"wxkbt-nohook-%d.txt", getpid()], out);
    }
}

#pragma mark - Dynamic hook: remove the "you can't enable more" gate

// Signature of canSetToolbarFunc:enabled: is uncertain across versions. We only
// install the forced-YES hook when the runtime type encoding proves the return
// type is BOOL/char, so we can never hand a bogus pointer back to WeType.
static BOOL WXKBT_ForcedCanSet(id self, SEL _cmd, id a1, BOOL a2) {
    (void)self; (void)_cmd; (void)a1; (void)a2;
    return YES;
}

static BOOL WXKBT_ReturnTypeIsBool(const char *enc) {
    if (enc == NULL || enc[0] == '\0') return NO;
    return (enc[0] == 'B' || enc[0] == 'c');
}

static void WXKBT_ForceUncapGates(void) {
    NSArray<NSString *> *sels = @[
        @"canSetToolbarFunc:enabled:",
        @"canAddToolbarFunc:",
        @"canAddToolBarFunc:",
        @"canAddToolbarFunc:source:",
    ];
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (classes == NULL) return;

    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"# wxkbt+ uncap gate probe\npid=%d\nbundle=%s\nexec=%s\n\n",
        getpid(),
        [[[NSBundle mainBundle] bundleIdentifier] UTF8String] ?: "nil",
        [[[NSBundle mainBundle] executablePath] UTF8String] ?: "nil"];

    for (NSString *selName in sels) {
        SEL sel = NSSelectorFromString(selName);
        [out appendFormat:@"[%@]\n", selName];
        for (unsigned int i = 0; i < count; i++) {
            Class cls = classes[i];
            unsigned int mc = 0;
            Method *ms = class_copyMethodList(cls, &mc);
            BOOL owns = NO; Method found = NULL;
            for (unsigned int j = 0; j < mc; j++) {
                if (method_getName(ms[j]) == sel) { owns = YES; found = ms[j]; break; }
            }
            free(ms);
            if (!owns || found == NULL) continue;

            const char *enc = method_getTypeEncoding(found);
            [out appendFormat:@"    %s  encoding=%s\n",
                class_getName(cls), ((enc != NULL) ? enc : "?"));
            if (!WXKBT_ReturnTypeIsBool(enc)) {
                [out appendFormat:@"      -> skipped (return type is not BOOL)\n"];
                continue;
            }
            method_setImplementation(found, (IMP)WXKBT_ForcedCanSet);
            [out appendFormat:@"      -> HOOKED to always return YES\n"];
            NSLog(@"[WXKBT+] uncapped -[%s %@]", class_getName(cls), selName);
        }
        [out appendString:@"\n"];
    }
    free(classes);

    WXKBT_WriteToAllLocations([NSString stringWithFormat:@"wxkbt-uncap-%d.txt", getpid()], out);
}

#pragma mark - Dynamic hook: raise the numeric cap (maxCount / countLimit)
//
// The on-disk metadata proved that both wxkb (app) and wxkb_plugin (keyboard
// extension) carry ivars `_maxCount` (Tq) and `_countLimit` (TQ) plus
// `_itemCount` / `_oriItemCount` / `_hasMoreItem`. That is the shape of a
// "how many items may this toolbar hold" cap. We only touch these two getters,
// and only on classes whose name is clearly toolbar-related, so unrelated
// limits (clipboard / hot-word / rate limiting) are untouched.

static long long WXKBT_ForcedCount(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return 999;
}

static BOOL WXKBT_EncodingLooksLikeIntegerGetter(const char *enc) {
    if (enc == NULL || enc[0] == '\0') return NO;
    char c = enc[0];
    if (c != 'q' && c != 'Q' && c != 'i' && c != 'I' && c != 'l' && c != 'L') return NO;
    // A getter has exactly one ':' (the 0:8 selector slot) and no other args.
    int colons = 0;
    for (const char *p = enc; *p; p++) if (*p == ':') colons++;
    return colons == 1;
}

static BOOL WXKBT_ClassIsToolbarScoped(NSString *name) {
    NSString *n = [name lowercaseString];
    return ([n rangeOfString:@"toolbar"].location != NSNotFound) ||
           ([n rangeOfString:@"tool bar"].location != NSNotFound) ||
           ([n rangeOfString:@"functiontool"].location != NSNotFound) ||
           ([n rangeOfString:@"funcitem"].location != NSNotFound);
}

static void WXKBT_OverrideCountLimits(void) {
    NSArray<NSString *> *getters = @[@"maxCount", @"countLimit"];
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (classes == NULL) return;

    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"# wxkbt+ count-limit override probe\npid=%d\nbundle=%s\nexec=%s\n",
        getpid(),
        [[[NSBundle mainBundle] bundleIdentifier] UTF8String] ?: "nil",
        [[[NSBundle mainBundle] executablePath] UTF8String] ?: "nil"];

    // Always report every class that owns these getters, so we learn the real
    // owner even when the name filter refuses to touch it.
    [out appendString:@"\n--- all owners ---\n"];

    for (NSString *selName in getters) {
        SEL sel = NSSelectorFromString(selName);
        for (unsigned int i = 0; i < count; i++) {
            Class cls = classes[i];
            unsigned int mc = 0;
            Method *ms = class_copyMethodList(cls, &mc);
            BOOL owns = NO; Method found = NULL;
            for (unsigned int j = 0; j < mc; j++) {
                if (method_getName(ms[j]) == sel) { owns = YES; found = ms[j]; break; }
            }
            free(ms);
            if (!owns || found == NULL) continue;

            const char *enc = method_getTypeEncoding(found);
            NSString *cname = [NSString stringWithUTF8String:class_getName(cls)];
            BOOL scoped = WXKBT_ClassIsToolbarScoped(cname);
            [out appendFormat:@"%@ -[%@ %@] enc=%s scoped=%s\n",
                scoped ? @"HOOK" : @"skip", cname, selName, ((enc != NULL) ? enc : "?"), scoped ? "yes" : "no"];

            if (!scoped) continue;
            if (!WXKBT_EncodingLooksLikeIntegerGetter(enc)) continue;
            method_setImplementation(found, (IMP)WXKBT_ForcedCount);
            NSLog(@"[WXKBT+] raised -[%@ %@] to 999", cname, selName);
        }
    }
    free(classes);

    WXKBT_WriteToAllLocations([NSString stringWithFormat:@"wxkbt-limits-%d.txt", getpid()], out);
}

#pragma mark - Runtime class/method dump (the ground truth we still need)

static NSArray<NSString *> *WXKBT_ProbeSelectors(void) {
    return @[
        @"canSetToolbarFunc:enabled:", @"setToolbarFunc:enabled:", @"setToolBarFunc:enabled:",
        @"setToolbarFuncs:", @"saveToolbarFuncs:editingSource:", @"toolbarFuncsForScene:",
        @"toolbarFuncsForScene:suggestedTypes:prefersRecent:",
        @"updateToolBarItems", @"updateToolBarIcons", @"initToolBarPanel",
        @"handleToolBarFuncEvent:suggestedType:controlEvent:",
        @"toolBar:requireChangeExpandState:", @"setToolBarShrunken:animated:",
        @"isToolbarFuncEnabled:", @"isToolbarDisplayingFunc:",
        @"setEdittingToolBarFunc:enabled:removeFromRecent:",
    ];
}

static BOOL WXKBT_ClassLooksInteresting(NSString *name) {
    if (name.length == 0) return NO;
    if ([name hasPrefix:@"UI"] || [name hasPrefix:@"NS"] ||
        [name hasPrefix:@"WK"] || [name hasPrefix:@"_"] ||
        [name hasPrefix:@"CA"] || [name hasPrefix:@"OS_"] ||
        [name hasPrefix:@"Swift"]) return NO;
    NSString *n = [name lowercaseString];
    NSArray<NSString *> *kws = @[
        @"tool", @"func", @"keyboard", @"keyplan", @"panel", @"emoji", @"voice",
        @"mic", @"globe", @"switch", @"translat", @"expand", @"shrink", @"shrunken",
        @"custom", @"toolbar", @"wbcc", @"wbkb", @"wetype", @"wbfunc",
    ];
    for (NSString *kw in kws) {
        if ([n rangeOfString:kw].location != NSNotFound) return YES;
    }
    return NO;
}

static void WXKBT_DumpRuntimeClasses(void) {
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (classes == NULL) return;

    NSMutableString *out = [NSMutableString string];
    [out appendString:@"# wxkbt+ runtime class dump\n"];
    [out appendFormat:@"pid=%d\n", getpid()];
    [out appendFormat:@"bundle=%s\n", [[[NSBundle mainBundle] bundleIdentifier] UTF8String] ?: "nil"];
    [out appendFormat:@"exec=%s\n", [[[NSBundle mainBundle] executablePath] UTF8String] ?: "nil"];
    [out appendFormat:@"home=%s\n", [NSHomeDirectory() UTF8String] ?: "nil"];
    [out appendFormat:@"loaded classes=%u\n\n", count];

    NSArray<NSString *> *probeSels = WXKBT_ProbeSelectors();
    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *index =
        [NSMutableDictionary dictionary];
    for (NSString *s in probeSels) index[s] = [NSMutableArray array];

    NSMutableString *classSection = [NSMutableString string];
    NSUInteger dumped = 0;

    for (unsigned int i = 0; i < count; i++) {
        Class cls = classes[i];
        const char *cn = class_getName(cls);
        if (cn == NULL) continue;
        NSString *name = [NSString stringWithUTF8String:cn];
        if (name == nil) continue;

        unsigned int mc = 0;
        Method *ms = class_copyMethodList(cls, &mc);
        if (ms == NULL) continue;

        for (unsigned int j = 0; j < mc; j++) {
            SEL sel = method_getName(ms[j]);
            if (sel == NULL) continue;
            NSString *sn = [NSString stringWithUTF8String:sel_getName(sel)];
            NSMutableArray *bucket = index[sn];
            if (bucket != nil) [bucket addObject:name];
        }

        if (WXKBT_ClassLooksInteresting(name) && classSection.length < 800000) {
            dumped++;
            Class sup = class_getSuperclass(cls);
            [classSection appendFormat:@"=== %@ : %s ===\n", name,
                sup ? class_getName(sup) : "-"];
            for (unsigned int j = 0; j < mc; j++) {
                SEL sel = method_getName(ms[j]);
                if (sel == NULL) continue;
                const char *enc = method_getTypeEncoding(ms[j]);
                [classSection appendFormat:@"  - %s   [%s]\n",
                    sel_getName(sel), ((enc != NULL) ? enc : "?")];
            }
            // class methods too
            unsigned int cmc = 0;
            Method *cms = class_copyMethodList(object_getClass(cls), &cmc);
            for (unsigned int j = 0; cms && j < cmc; j++) {
                [classSection appendFormat:@"  + %s\n", sel_getName(method_getName(cms[j]))];
            }
            free(cms);
            [classSection appendString:@"\n"];
        }
        free(ms);
    }
    free(classes);

    [out appendString:@"===== REVERSE INDEX (selector -> classes implementing it) =====\n\n"];
    for (NSString *s in probeSels) {
        NSArray *bucket = index[s];
        [out appendFormat:@"[%@] (%lu)\n", s, (unsigned long)bucket.count];
        for (NSString *cn in bucket) [out appendFormat:@"    %@\n", cn];
        [out appendString:@"\n"];
    }

    [out appendFormat:@"\n===== INTERESTING CLASSES (%lu) =====\n\n", (unsigned long)dumped];
    [out appendString:classSection];

    NSString *basename = [NSString stringWithFormat:@"wxkbt-runtime-%d.txt", getpid()];
    BOOL ok = WXKBT_WriteToAllLocations(basename, out);
    NSLog(@"[WXKBT+] runtime dump: %lu classes, %lu bytes, written=%d",
          (unsigned long)dumped, (unsigned long)out.length, ok);
    (void)ok;
}

#pragma mark - On-disk Mach-O ObjC metadata dump (SpringBoard side)

static uint32_t WXKBT_BESwap32(uint32_t x) {
    return ((x & 0x000000FFu) << 24) | ((x & 0x0000FF00u) << 8) |
           ((x & 0x00FF0000u) >> 8)  | ((x & 0xFF000000u) >> 24);
}

static NSArray<NSString *> *WXKBT_SplitNullStrings(NSData *blob) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    if (blob.length == 0) return out;
    const uint8_t *bytes = (const uint8_t *)blob.bytes;
    NSUInteger len = blob.length;
    NSUInteger start = 0;
    for (NSUInteger i = 0; i < len; i++) {
        if (bytes[i] == 0) {
            if (i > start) {
                NSString *s = [[NSString alloc] initWithBytes:(bytes + start)
                                                      length:(i - start)
                                                    encoding:NSUTF8StringEncoding];
                if (s.length > 0) [out addObject:s];
            }
            start = i + 1;
        }
    }
    return out;
}

static NSArray<NSString *> *WXKBT_FilterStrings(NSArray<NSString *> *all,
                                                NSArray<NSString *> *keywords,
                                                NSUInteger cap) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSString *s in all) {
        if (s.length == 0 || s.length > 200) continue;
        BOOL hit = NO;
        for (NSString *kw in keywords) {
            if ([s rangeOfString:kw options:NSCaseInsensitiveSearch].location != NSNotFound) {
                hit = YES; break;
            }
        }
        if (!hit) continue;
        if ([seen containsObject:s]) continue;
        [seen addObject:s];
        [out addObject:s];
        if (out.count >= cap) break;
    }
    return out;
}

static NSArray<NSString *> *WXKBT_ClassKeywords(void) {
    return @[ @"tool", @"bar", @"panel", @"button", @"btn", @"key", @"board",
              @"wx", @"type", @"input", @"menu", @"more", @"func", @"item",
              @"icon", @"emoji", @"mic", @"voice", @"ai", @"globe",
              @"arrow", @"chevron", @"simpl", @"tradition", @"layout",
              @"limit", @"max", @"count", @"select", @"custom", @"toolbar" ];
}

static NSArray<NSString *> *WXKBT_MethodKeywords(void) {
    return @[ @"toolbar", @"panel", @"limit", @"maxcount", @"additem",
              @"selectitem", @"enableitem", @"itemcount", @"numberof",
              @"moreitem", @"canadd", @"addtool", @"toolitem" ];
}

static NSDictionary<NSString *, NSData *> *WXKBT_ExtractObjCSections(NSData *data) {
    if (data.length < 128) return nil;
    const uint8_t *base = (const uint8_t *)data.bytes;
    NSUInteger len = data.length;

    NSUInteger sliceOff = 0;
    uint32_t magic = *(const uint32_t *)base;
    if (magic == FAT_MAGIC || magic == FAT_CIGAM) {
        const struct fat_header *fh = (const struct fat_header *)base;
        uint32_t nfat = WXKBT_BESwap32(fh->nfat_arch);
        if (nfat > 64) nfat = 64;
        const struct fat_arch *archs =
            (const struct fat_arch *)(base + sizeof(struct fat_header));
        BOOL picked = NO;
        for (uint32_t i = 0; i < nfat; i++) {
            uint32_t cputype = WXKBT_BESwap32(archs[i].cputype);
            uint32_t off     = WXKBT_BESwap32(archs[i].offset);
            if (cputype == CPU_TYPE_ARM64) { sliceOff = off; picked = YES; break; }
        }
        if (!picked && nfat > 0) sliceOff = WXKBT_BESwap32(archs[0].offset);
    }

    if (sliceOff + sizeof(struct mach_header_64) > len) return nil;
    const struct mach_header_64 *mh = (const struct mach_header_64 *)(base + sliceOff);
    if (mh->magic != MH_MAGIC_64) return nil;

    NSUInteger off = sliceOff + sizeof(struct mach_header_64);
    NSMutableDictionary<NSString *, NSData *> *result = [NSMutableDictionary dictionary];
    for (uint32_t i = 0; i < mh->ncmds && off + sizeof(struct load_command) <= len; i++) {
        const struct load_command *lc = (const struct load_command *)(base + off);
        if (lc->cmdsize == 0) break;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            if (strncmp(seg->segname, "__TEXT", sizeof(seg->segname)) == 0) {
                const struct section_64 *sects =
                    (const struct section_64 *)((const uint8_t *)seg +
                                                sizeof(struct segment_command_64));
                for (uint32_t j = 0; j < seg->nsects; j++) {
                    const struct section_64 *s = &sects[j];
                    // "__objc_classname" is exactly 16 chars and fills
                    // char sectname[16] with NO null terminator: compare raw bytes.
                    BOOL isClass = strncmp(s->sectname, "__objc_classname",
                                           sizeof(s->sectname)) == 0;
                    BOOL isMeth  = strncmp(s->sectname, "__objc_methname",
                                           sizeof(s->sectname)) == 0;
                    if (!isClass && !isMeth) continue;
                    NSUInteger so = sliceOff + (NSUInteger)s->offset;
                    NSUInteger sz = (NSUInteger)s->size;
                    if (so + sz <= len && sz > 0) {
                        NSString *key = isClass ? @"__objc_classname" : @"__objc_methname";
                        result[key] = [data subdataWithRange:NSMakeRange(so, sz)];
                    }
                }
            }
        }
        off += lc->cmdsize;
    }
    return result.count > 0 ? result : nil;
}

static void WXKBT_DumpObjCFromBinary(NSString *binPath, NSString *tag) {
    NSData *data = [NSData dataWithContentsOfFile:binPath];
    if (data == nil) return;

    NSDictionary<NSString *, NSData *> *sections = WXKBT_ExtractObjCSections(data);
    if (sections == nil) return;

    NSArray<NSString *> *classes = WXKBT_SplitNullStrings(sections[@"__objc_classname"]);
    NSArray<NSString *> *methods = WXKBT_SplitNullStrings(sections[@"__objc_methname"]);
    NSArray<NSString *> *classHits  = WXKBT_FilterStrings(classes, WXKBT_ClassKeywords(), 3000);
    NSArray<NSString *> *methodHits = WXKBT_FilterStrings(methods, WXKBT_MethodKeywords(), 3000);

    NSMutableString *out = [NSMutableString string];
    [out appendString:@"# wxkbt+ objc metadata dump\n"];
    [out appendFormat:@"# binary  : %@\n", binPath];
    [out appendFormat:@"# classes : %lu total / %lu hits\n",
        (unsigned long)classes.count, (unsigned long)classHits.count];
    [out appendFormat:@"# methods : %lu total / %lu hits\n\n",
        (unsigned long)methods.count, (unsigned long)methodHits.count];
    [out appendString:@"===== CLASS NAME HITS =====\n"];
    for (NSString *s in classHits) [out appendFormat:@"%@\n", s];
    [out appendString:@"\n===== METHOD NAME HITS =====\n"];
    for (NSString *s in methodHits) [out appendFormat:@"%@\n", s];

    WXKBT_WriteToAllLocations([NSString stringWithFormat:@"wxkbt-objcdump-%@.txt", tag], out);
}

static void WXKBT_DumpAllWeTypeObjC(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *roots = @[
        @"/var/containers/Bundle/Application",
        @"/var/jb/var/containers/Bundle/Application",
    ];
    for (NSString *root in roots) {
        for (NSString *uuid in [fm contentsOfDirectoryAtPath:root error:NULL] ?: @[]) {
            NSString *uuidDir = [root stringByAppendingPathComponent:uuid];
            if ([uuid hasPrefix:@".jbroot-"]) continue;   // avoid the jbroot mirror
            for (NSString *app in [fm contentsOfDirectoryAtPath:uuidDir error:NULL] ?: @[]) {
                if (![app hasSuffix:@".app"]) continue;
                NSString *appPath = [uuidDir stringByAppendingPathComponent:app];
                NSDictionary *appInfo = [NSDictionary dictionaryWithContentsOfFile:
                    [appPath stringByAppendingPathComponent:@"Info.plist"]];
                NSString *bid = appInfo[@"CFBundleIdentifier"] ?: @"";
                if ([bid rangeOfString:@"wetype" options:NSCaseInsensitiveSearch].location == NSNotFound) continue;

                NSString *appExec = appInfo[@"CFBundleExecutable"];
                if (appExec.length > 0) {
                    WXKBT_DumpObjCFromBinary([appPath stringByAppendingPathComponent:appExec],
                                             [NSString stringWithFormat:@"app-%@", appExec]);
                }
                NSString *plugDir = [appPath stringByAppendingPathComponent:@"PlugIns"];
                for (NSString *pl in [fm contentsOfDirectoryAtPath:plugDir error:NULL] ?: @[]) {
                    if (![pl hasSuffix:@".appex"]) continue;
                    NSString *plPath = [plugDir stringByAppendingPathComponent:pl];
                    NSDictionary *plInfo = [NSDictionary dictionaryWithContentsOfFile:
                        [plPath stringByAppendingPathComponent:@"Info.plist"]];
                    NSString *plExec = plInfo[@"CFBundleExecutable"];
                    if (plExec.length == 0) continue;
                    WXKBT_DumpObjCFromBinary([plPath stringByAppendingPathComponent:plExec],
                                             [NSString stringWithFormat:@"appex-%@", plExec]);
                }
            }
        }
    }
}

#pragma mark - Process scan (SpringBoard side, informational)

static void WXKBT_ScanRunningProcs(void) {
    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"# wxkbt+ process scan (pid=%d)\n\n", getpid()];

    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t bufSize = 0;
    if (sysctl(mib, 4, NULL, &bufSize, NULL, 0) != 0 || bufSize == 0) {
        [out appendString:@"# sysctl query failed\n"];
        WXKBT_WriteToAllLocations(@"wxkbt-procs.txt", out);
        return;
    }
    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(bufSize);
    if (procs == NULL) return;
    if (sysctl(mib, 4, procs, &bufSize, NULL, 0) != 0) { free(procs); return; }
    int total = (int)(bufSize / sizeof(struct kinfo_proc));
    int interesting = 0;
    for (int i = 0; i < total; i++) {
        const char *name = procs[i].kp_proc.p_comm;
        if (name == NULL || name[0] == '\0') continue;
        NSString *pname = [[NSString stringWithUTF8String:name] lowercaseString];
        BOOL hit = NO;
        for (NSString *kw in @[@"wxkb", @"wetype", @"keyboard", @"input"]) {
            if ([pname rangeOfString:kw].location != NSNotFound) { hit = YES; break; }
        }
        if (!hit) continue;
        [out appendFormat:@"pid=%d name=%s\n", procs[i].kp_proc.p_pid, name];
        interesting++;
    }
    free(procs);
    [out appendFormat:@"\n# interesting: %d / %d total\n", interesting, total];
    WXKBT_WriteToAllLocations(@"wxkbt-procs.txt", out);
}

#pragma mark - Constructor

%ctor {
    @autoreleasepool {
        NSString *mb = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
        NSString *me = [[NSBundle mainBundle] executablePath] ?: @"";

        WXKBT_WriteBootInfo("loaded");
        NSLog(@"[WXKBT+] loaded pid=%d bundle=%@ exec=%@", getpid(), mb, me);

        BOOL isSpringBoard = [mb isEqualToString:@"com.apple.springboard"];
        BOOL isWeType = ([mb rangeOfString:@"wetype" options:NSCaseInsensitiveSearch].location != NSNotFound) ||
                        ([me rangeOfString:@"wxkb" options:NSCaseInsensitiveSearch].location != NSNotFound) ||
                        ([me rangeOfString:@"wetype" options:NSCaseInsensitiveSearch].location != NSNotFound);

        if (isSpringBoard) {
            // SpringBoard: filesystem forensics + relay so we can read what the
            // sandboxed app/extension wrote into their own containers.
            WXKBT_ScanRunningProcs();
            WXKBT_DumpAllWeTypeObjC();
            WXKBT_StartSpringBoardRelay();
            return;
        }

        if (isWeType) {
            // We are inside WeType (app or keyboard extension): this is where
            // the real work happens.
            WXKBT_HookToolbarLayouts();   // make the toolbar row scrollable
            WXKBT_ForceUncapGates();      // lift the "can't enable more" gate
            WXKBT_OverrideCountLimits();  // raise maxCount / countLimit to 999
            WXKBT_DumpRuntimeClasses();   // full class->method ground truth
        }
    }
}
