// WXKeyboardToolbarPlus
// Theos + Logos tweak for WeType (微信输入法) keyboard extension.
// Hook WXKeyboardToolbarView: replace the 7-button hard cap with a horizontally
// scrollable container; expose per-button visibility via PreferenceLoader.
//
// Hard rules:
//   - DO NOT recreate the buttons. We just reparent them into a UIScrollView
//     while preserving each button's existing frame, so target/action chains,
//     icons and hit-testing are 100% identical to the originals.
//   - DO NOT swizzle global methods (UIView +load / +initialize / layoutSubviews).
//     We only hook a concrete class, so it stays compatible with liquid-glass
//     keyboard beautifier tweaks.
//   - DO NOT touch /var/mobile. RootHide/rootless path resolution is handled
//     by Theos; we never hardcode absolute paths.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <sys/sysctl.h>
#import <sys/types.h>
#import <mach-o/loader.h>
#import <mach-o/fat.h>
#import <mach/machine.h>
#import <string.h>
#import <stdlib.h>

#pragma mark - Preference keys

// Preference domain is the one PreferenceLoader plist uses for `defaults`.
// Defined as a string constant here purely for the boot-time NSLog below,
// so all the per-button keys stay grouped with their domain in source.
static NSString * const kPrefDomain        = @"com.gusing.wxkbtoolbarplus";
static NSString * const kPrefEnabled       = @"Enabled";          // BOOL
static NSString * const kPrefHidePanel     = @"HidePanel";        // BOOL  收起/扩展面板（向下箭头）
static NSString * const kPrefHideVoice     = @"HideVoice";        // BOOL  语音麦克风
static NSString * const kPrefHideEmoji     = @"HideEmoji";        // BOOL  表情面板
static NSString * const kPrefHideAI        = @"HideAI";           // BOOL  AI 智能输入
static NSString * const kPrefHideSimplify  = @"HideSimplify";     // BOOL  繁简切换
static NSString * const kPrefHideKeyboard  = @"HideKeyboard";     // BOOL  键盘切换

#pragma mark - Runtime marker key (associated object)

static const void *kScrollContainerKey = &kScrollContainerKey;
static const NSInteger kScrollViewTag    = 0x5758BEEF; // "WX" + 任意不冲突 tag

#pragma mark - Utility: button identifier

static NSString *WXKBT_IdentForButton(UIView *btn) {
    NSString *acc = btn.accessibilityIdentifier;
    if (acc.length > 0) return acc;
    NSString *label = btn.accessibilityLabel;
    if (label.length > 0) return label;
    Class cls = [btn class];
    const char *cn = class_getName(cls);
    NSString *clsName = (cn != NULL) ? [NSString stringWithUTF8String:cn] : @"Button";
    if (btn.tag != 0) {
        return [NSString stringWithFormat:@"%@_%ld", clsName, (long)btn.tag];
    }
    // Last resort: hash class name + position. Good enough for matching by keyword.
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

#pragma mark - Hook

%hook WXKeyboardToolbarView

// layoutSubviews runs every time the toolbar geometry is recomputed by the
// host UIKit. We piggy-back on it: after the original layout is done, we
// (a) lazily create a UIScrollView,
// (b) reparent every UIControl subview (the toolbar buttons) into it,
//     preserving frame,
// (c) size the scroll view to fill self.bounds and recompute contentSize,
// (d) apply PreferenceLoader visibility flags.
- (void)layoutSubviews {
    %orig;  // original code: lays out buttons as it always did

    // (a) lazily create the scroll container
    UIScrollView *scroll = (UIScrollView *)objc_getAssociatedObject(self, kScrollContainerKey);
    if (scroll == nil) {
        scroll = [[UIScrollView alloc] init];
        scroll.showsHorizontalScrollIndicator = NO;
        scroll.showsVerticalScrollIndicator   = NO;
        scroll.bounces                        = YES;
        scroll.alwaysBounceHorizontal         = YES;
        scroll.backgroundColor                = [UIColor clearColor];
        scroll.userInteractionEnabled         = YES;
        scroll.multipleTouchEnabled           = NO;
        scroll.tag                            = kScrollViewTag;
        // Put the scroll view at the bottom of the stack so it doesn't
        // visually cover anything while we still want the original
        // background (e.g. blur) of self to show through.
        // Logos leaves WXKeyboardToolbarView as a forward declaration inside
        // the %hook block, so cast self to UIView * for the UIView API.
        [(UIView *)self insertSubview:scroll atIndex:0];
        objc_setAssociatedObject(self, kScrollContainerKey, scroll,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    // (b) reparent every UIControl subview (preserving its current frame)
    NSMutableArray<UIView *> *toMove = [NSMutableArray array];
    for (UIView *sub in [(UIView *)self subviews]) {
        if (sub == scroll) continue;
        if ([sub isKindOfClass:[UIControl class]]) {
            [toMove addObject:sub];
        }
    }
    for (UIView *btn in toMove) {
        CGRect originalFrame = [btn frame];
        [btn removeFromSuperview];
        [btn setFrame:originalFrame];   // same frame, just in a new container
        [scroll addSubview:btn];
    }

    // (c) size the scroll container to fill the toolbar bounds and compute contentSize
    CGRect bounds = [(UIView *)self bounds];
    [scroll setFrame:bounds];
    CGFloat maxRight = 0;
    for (UIView *sub in [scroll subviews]) {
        CGFloat r = CGRectGetMaxX([sub frame]);
        if (r > maxRight) maxRight = r;
    }
    CGFloat contentWidth = MAX(maxRight + 16.0, CGRectGetWidth(bounds));
    [scroll setContentSize:CGSizeMake(contentWidth, CGRectGetHeight(bounds))];

    // (d) apply visibility flags from PreferenceLoader
    NSUserDefaults *def = [NSUserDefaults standardUserDefaults];
    BOOL master = [def boolForKey:kPrefEnabled];

    if (!master) {
        // master switch off: don't touch button visibility at all, just keep
        // everything visible. This is the safe default and also makes the
        // tweak inert if the user disables it.
        for (UIView *btn in [scroll subviews]) {
            [btn setHidden:NO];
        }
        return;
    }

    // Keyword sets. These are intentionally broad so they match whatever
    // concrete subclass WeType uses for each button (which has changed
    // across versions). The user can refine them after class-dumping the
    // keyboard extension binary.
    NSDictionary<NSString *, NSArray<NSString *> *> *keywordMap = @{
        kPrefHidePanel:    @[@"panel", @"chevron", @"arrow", @"expand", @"close"],
        kPrefHideVoice:    @[@"voice", @"mic", @"audio", @"speak", @"dictation"],
        kPrefHideEmoji:    @[@"emoji", @"sticker", @"face", @"expression"],
        kPrefHideAI:       @[@"ai", @"smart", @"assistant", @"wenan", @"灵感"],
        kPrefHideSimplify: @[@"simplif", @"tradition", @"繁体", @"繁简", @"chinese"],
        kPrefHideKeyboard: @[@"globe", @"keyboard", @"world", @"切换键盘", @"switch"],
    };

    NSMutableSet<NSString *> *hiddenIdents = [NSMutableSet set];
    for (NSString *prefKey in keywordMap) {
        if ([def boolForKey:prefKey]) {
            [hiddenIdents addObject:prefKey];
        }
    }

    for (UIView *btn in [scroll subviews]) {
        NSString *ident = WXKBT_IdentForButton(btn);
        BOOL shouldHide = NO;
        for (NSString *prefKey in hiddenIdents) {
            NSArray<NSString *> *kws = keywordMap[prefKey];
            if (WXKBT_MatchesKeyword(ident, kws)) {
                shouldHide = YES;
                break;
            }
        }
        [btn setHidden:shouldHide];
    }
}

%end

#pragma mark - Constructor: verify the hook target exists

#pragma mark - Diagnostic helpers

// Forward decls so the constructor below can call them; full bodies appear
// after %ctor (Theos compiles with -Werror, "static fn used before declared" — hard fail).
static void WXKBT_DumpClassesToFile(void);
static void WXKBT_WriteBootInfo(const char *status);
static void WXKBT_ScanForWeTypeAppex(void);
static void WXKBT_ScanRunningProcs(void);
static void WXKBT_DumpAllWeTypeObjC(void);
static void WXKBT_DumpRuntimeToolbarClasses(void);
static BOOL WXKBT_PathLooksInteresting(NSString *s);

%ctor {
    NSLog(@"[WXKBT+] tweak loaded in pid=%d (domain=%@).",
          getpid(), kPrefDomain);

    // ALWAYS write the boot-info file so we can confirm the tweak loaded
    // in some process. If main_bundle is com.apple.springboard we know we
    // hit SpringBoard but not the keyboard extension — that's our main
    // problem to solve.
    WXKBT_WriteBootInfo("loaded");

    // If we land in the WeType keyboard extension / main app, dump the real
    // runtime class list + method lists for every toolbar-ish class. THIS is
    // the ground truth we actually need.
    NSString *mb = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    NSString *me = [[NSBundle mainBundle] executablePath] ?: @"";
    if (WXKBT_PathLooksInteresting(mb) || WXKBT_PathLooksInteresting(me) ||
        [me rangeOfString:@"wxkb"].location != NSNotFound) {
        WXKBT_DumpRuntimeToolbarClasses();
        WXKBT_ScanForWeTypeAppex();
    }

    // If we landed in SpringBoard, run the on-disk binary forensics.
    if ([mb isEqualToString:@"com.apple.springboard"] || mb.length == 0) {
        WXKBT_ScanForWeTypeAppex();
        WXKBT_ScanRunningProcs();
        WXKBT_DumpAllWeTypeObjC();
    }

    // Probe the candidate toolbar classes we discovered from the binary dump.
    NSArray<NSString *> *candidates = @[
        @"WXKeyboardToolbarView", @"WBFunctionToolBar", @"WBCustomToolBarView",
        @"WBToolBarButton", @"WBCombinedToolBarButton", @"WBTranslateViewToolBar",
        @"WBToolBarAuxiliary", @"WBCCFuncItem"
    ];
    for (NSString *c in candidates) {
        NSLog(@"[WXKBT+] probe %@ -> %@", c,
              objc_getClass([c UTF8String]) ? @"FOUND" : @"missing");
    }

    // Now check for our hook target class.
    Class cls = objc_getClass("WXKeyboardToolbarView");
    if (cls == NULL) {
        NSLog(@"[WXKBT+] WXKeyboardToolbarView not found; trying WBFunctionToolBar.");
        cls = objc_getClass("WBFunctionToolBar");
    }
    if (cls == NULL) {
        NSLog(@"[WXKBT+] no known toolbar class found in this process.");
        WXKBT_DumpClassesToFile();
        return;
    }
    NSLog(@"[WXKBT+] toolbar class present: %s", class_getName(cls));
}

// Always-on boot marker: writes a per-pid file under several locations so
// we can tell which processes the tweak actually loaded into, regardless of
// whether WXKeyboardToolbarView was found. The user pulls these via Filza.
//
// We write to (a) /var/mobile/Documents (user-friendly, may be blocked by
// some app-extension sandboxes), (b) /tmp (always writable, ephemeral) and
// (c) /var/jb/var/mobile/Documents (rootless-friendly path).
static void WXKBT_WriteToAllLocations(NSString *basename, NSString *body) {
    NSArray<NSString *> *dirs = @[
        @"/var/mobile/Documents",
        @"/tmp",
        @"/var/jb/var/mobile/Documents",
        @"/var/jb/tmp",
    ];
    for (NSString *dir in dirs) {
        NSString *path = [dir stringByAppendingPathComponent:basename];
        NSError *err = nil;
        BOOL ok = [body writeToFile:path atomically:YES
                          encoding:NSUTF8StringEncoding
                             error:&err];
        NSLog(@"[WXKBT+] write %@ -> %@ (err=%@)",
              ok ? @"OK  " : @"FAIL", path, err);
    }
}

static void WXKBT_WriteBootInfo(const char *status) {
    NSMutableString *info = [NSMutableString string];
    [info appendFormat:@"pid=%d\n", getpid()];
    [info appendFormat:@"status=%s\n", status];
    [info appendFormat:@"main_bundle=%s\n", [[[NSBundle mainBundle] bundleIdentifier] UTF8String] ?: "nil"];
    [info appendFormat:@"main_exec=%s\n", [[[NSBundle mainBundle] executablePath] UTF8String] ?: "nil"];
    NSString *basename = [NSString stringWithFormat:@"wxkbt-info-%d.txt", getpid()];
    WXKBT_WriteToAllLocations(basename, info);
}

// Diagnostic helper: write all loaded ObjC class names matching Keyboard/
// Toolbar/Tool/Type/Input to a per-pid file under /var/mobile/Documents/
// so the user can pull the file and tell us the real toolbar class name.
static void WXKBT_DumpClassesToFile(void) {
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (classes == NULL) return;

    NSMutableString *report = [NSMutableString string];
    [report appendFormat:@"# wxkbt+ class dump pid=%d bundle=%s\n",
        getpid(),
        [[[NSBundle mainBundle] bundleIdentifier] UTF8String] ?: "nil"];
    [report appendString:@"# look for lines containing 'Toolbar' / 'Tool' / 'Keyboard' / 'Wetype' / 'WX'\n\n"];

    NSArray<NSString *> *keywords = @[@"Toolbar", @"Keyboard", @"Tool", @"Input", @"Wetype", @"WX"];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (unsigned int i = 0; i < count; i++) {
        const char *cname = class_getName(classes[i]);
        if (cname == NULL) continue;
        NSString *name = [NSString stringWithUTF8String:cname];
        for (NSString *kw in keywords) {
            if ([name rangeOfString:kw options:NSCaseInsensitiveSearch].location != NSNotFound) {
                if (![seen containsObject:name]) {
                    [seen addObject:name];
                    [report appendFormat:@"%@\n", name];
                }
                break;
            }
        }
    }
    free(classes);

    NSString *basename = [NSString stringWithFormat:@"wxkbt-classes-%d.txt", getpid()];
    WXKBT_WriteToAllLocations(basename, report);
    NSLog(@"[WXKBT+] class dump %lu lines (basename=%@)",
          (unsigned long)seen.count, basename);
}

// ---------------------------------------------------------------------------
// SpringBoard-only scans: enumerate .appex files on disk + running processes
// matching keyboard/wetype/input patterns. The output is what we use to
// refine the filter plist.
//
// We do this in SpringBoard because SpringBoard runs the tweak (filter
// includes com.apple.springboard) AND has unrestricted filesystem access.
// If we waited until the keyboard extension process loaded the tweak, we'd
// be too late — that process never loads the tweak because we don't know
// its bundle id yet.
// ---------------------------------------------------------------------------
static BOOL WXKBT_PathLooksInteresting(NSString *s) {
    NSString *lc = [s lowercaseString];
    for (NSString *kw in @[@"wetype", @"wxkb", @"input", @"keyboard", @"tencent"]) {
        if ([lc rangeOfString:kw].location != NSNotFound) return YES;
    }
    return NO;
}

static BOOL WXKBT_IsOurApp(NSString *appPath) {
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
        [appPath stringByAppendingPathComponent:@"Info.plist"]];
    if (info == nil) return NO;
    return WXKBT_PathLooksInteresting(info[@"CFBundleIdentifier"] ?: @"") ||
           WXKBT_PathLooksInteresting(info[@"CFBundleName"] ?: @"") ||
           WXKBT_PathLooksInteresting([appPath lastPathComponent] ?: @"");
}

static void WXKBT_ScanForWeTypeAppex(void) {
    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"# wxkbt+ appex filesystem scan (pid=%d, bundle=%@)\n",
        getpid(), [[NSBundle mainBundle] bundleIdentifier] ?: @"nil"];
    [out appendString:@"# Format: <full .appex path> | CFBundleIdentifier | CFBundleExecutable\n\n"];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *roots = @[
        @"/var/containers/Bundle/Application",
        @"/var/jb/var/containers/Bundle/Application",
    ];
    NSUInteger found = 0;

    for (NSString *root in roots) {
        NSError *err = nil;
        NSArray<NSString *> *uuids = [fm contentsOfDirectoryAtPath:root error:&err];
        if (uuids == nil) { [out appendFormat:@"# err %@: %@\n", root, err]; continue; }

        for (NSString *uuid in uuids) {
            NSString *uuidDir = [root stringByAppendingPathComponent:uuid];
            NSArray<NSString *> *apps = [fm contentsOfDirectoryAtPath:uuidDir error:NULL];
            if (apps == nil) continue;

            for (NSString *app in apps) {
                if (![app hasSuffix:@".app"]) continue;
                NSString *appFull = [uuidDir stringByAppendingPathComponent:app];
                if (!WXKBT_IsOurApp(appFull)) continue;

                NSDictionary *appInfo = [NSDictionary dictionaryWithContentsOfFile:
                    [appFull stringByAppendingPathComponent:@"Info.plist"]];
                [out appendFormat:@"APP: %@\n  bundle=%@\n  name=%@\n  exec=%@\n",
                    appFull,
                    appInfo[@"CFBundleIdentifier"] ?: @"?",
                    appInfo[@"CFBundleName"] ?: @"?",
                    appInfo[@"CFBundleExecutable"] ?: @"?"];

                NSString *pluginDir = [appFull stringByAppendingPathComponent:@"PlugIns"];
                NSArray<NSString *> *plugins = [fm contentsOfDirectoryAtPath:pluginDir error:NULL];
                if (plugins == nil) {
                    [out appendFormat:@"  (no PlugIns dir under %@)\n", appFull];
                    continue;
                }
                for (NSString *plugin in plugins) {
                    if (![plugin hasSuffix:@".appex"]) continue;
                    NSString *pluginFull = [pluginDir stringByAppendingPathComponent:plugin];
                    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                        [pluginFull stringByAppendingPathComponent:@"Info.plist"]];
                    [out appendFormat:@"  APPEX: %@\n    bundle=%@\n    exec=%@\n",
                        pluginFull,
                        info[@"CFBundleIdentifier"] ?: @"?",
                        info[@"CFBundleExecutable"] ?: @"?"];
                    found++;
                }
            }
        }
    }

    [out appendFormat:@"\n# total appex found: %lu\n", (unsigned long)found];
    NSString *basename = @"wxkbt-appex-scan.txt";
    WXKBT_WriteToAllLocations(basename, out);
    NSLog(@"[WXKBT+] appex scan: %lu hits", (unsigned long)found);
}

static void WXKBT_ScanRunningProcs(void) {
    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"# wxkbt+ running-process scan (pid=%d, bundle=%@)\n",
        getpid(), [[NSBundle mainBundle] bundleIdentifier] ?: @"nil"];
    [out appendString:@"# Format: <pid> <process-name>\n\n"];

    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t bufSize = 0;
    if (sysctl(mib, 4, NULL, &bufSize, NULL, 0) != 0 || bufSize == 0) {
        [out appendString:@"# sysctl query failed\n"];
        WXKBT_WriteToAllLocations(@"wxkbt-procs-scan.txt", out);
        return;
    }

    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(bufSize);
    if (procs == NULL) {
        [out appendString:@"# malloc failed\n"];
        WXKBT_WriteToAllLocations(@"wxkbt-procs-scan.txt", out);
        return;
    }
    if (sysctl(mib, 4, procs, &bufSize, NULL, 0) != 0) {
        free(procs);
        [out appendString:@"# sysctl read failed\n"];
        WXKBT_WriteToAllLocations(@"wxkbt-procs-scan.txt", out);
        return;
    }
    int total = (int)(bufSize / sizeof(struct kinfo_proc));
    int interesting = 0;
    for (int i = 0; i < total; i++) {
        const char *name = procs[i].kp_proc.p_comm;
        if (name == NULL || name[0] == '\0') continue;
        NSString *pname = [NSString stringWithUTF8String:name];
        if (!WXKBT_PathLooksInteresting(pname)) continue;
        [out appendFormat:@"pid=%d name=%s\n", procs[i].kp_proc.p_pid, name];
        interesting++;
    }
    free(procs);

    [out appendFormat:@"\n# interesting: %d / %d total\n", interesting, total];
    NSString *basename = @"wxkbt-procs-scan.txt";
    WXKBT_WriteToAllLocations(basename, out);
    NSLog(@"[WXKBT+] proc scan: %d / %d interesting", interesting, total);
}

// ---------------------------------------------------------------------------
// Ground-truth ObjC metadata extraction from on-disk WeType binaries.
//
// We can't easily ssh into the device or ship a 50MB .appex binary to a PC.
// But Mach-O __objc_classname / __objc_methname sections are just plain
// null-terminated C strings. So the tweak (running in SpringBoard, which has
// filesystem access) locates the WeType binaries, parses those two sections
// and writes small keyword-filtered text files the user can read in Filza.
//
// This is how we finally learn (a) the real toolbar class and (b) whatever
// class enforces the 7-item cap.
// ---------------------------------------------------------------------------

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

// Raw fallback: pull every plausible ObjC identifier out of the byte stream.
static NSArray<NSString *> *WXKBT_RawIdentifierScan(NSData *data) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    const uint8_t *b = (const uint8_t *)data.bytes;
    NSUInteger len = data.length;
    NSUInteger start = NSNotFound;
    for (NSUInteger i = 0; i <= len; i++) {
        BOOL ok = NO;
        if (i < len) {
            uint8_t c = b[i];
            ok = ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                  (c >= '0' && c <= '9') || c == '_');
        }
        if (ok) {
            if (start == NSNotFound) start = i;
        } else if (start != NSNotFound) {
            NSUInteger l = i - start;
            if (l >= 4 && l <= 120) {
                NSString *s = [[NSString alloc] initWithBytes:(b + start)
                                                      length:l
                                                    encoding:NSUTF8StringEncoding];
                if (s != nil && ![seen containsObject:s]) {
                    [seen addObject:s];
                    [out addObject:s];
                }
            }
            start = NSNotFound;
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
                hit = YES;
                break;
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

// Returns @{ @"__objc_classname": NSData, @"__objc_methname": NSData } or nil.
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
                    // NOTE: "__objc_classname" is exactly 16 chars and fills
                    // char sectname[16] with NO null terminator, so we must
                    // compare the raw 16 bytes — stringWithUTF8String would
                    // read out of bounds and never match.
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

static void WXKBT_WriteObjCReport(NSString *binPath, NSString *tag,
                                  NSArray<NSString *> *classes,
                                  NSArray<NSString *> *methods,
                                  NSString *note) {
    NSArray<NSString *> *classHits  = WXKBT_FilterStrings(classes, WXKBT_ClassKeywords(), 3000);
    NSArray<NSString *> *methodHits = WXKBT_FilterStrings(methods, WXKBT_MethodKeywords(), 3000);

    NSMutableString *out = [NSMutableString string];
    [out appendString:@"# wxkbt+ objc metadata dump\n"];
    [out appendFormat:@"# binary  : %@\n", binPath];
    [out appendFormat:@"# tag     : %@\n", tag];
    [out appendFormat:@"# note    : %@\n", note];
    [out appendFormat:@"# classes : %lu total / %lu hits\n",
        (unsigned long)classes.count, (unsigned long)classHits.count];
    [out appendFormat:@"# methods : %lu total / %lu hits\n\n",
        (unsigned long)methods.count, (unsigned long)methodHits.count];
    [out appendString:@"===== CLASS NAME HITS =====\n"];
    for (NSString *s in classHits) [out appendFormat:@"%@\n", s];
    [out appendString:@"\n===== METHOD NAME HITS =====\n"];
    for (NSString *s in methodHits) [out appendFormat:@"%@\n", s];

    NSString *basename = [NSString stringWithFormat:@"wxkbt-objcdump-%@.txt", tag];
    WXKBT_WriteToAllLocations(basename, out);
    NSLog(@"[WXKBT+] objc dump %@: %lu classes / %lu methods",
          tag, (unsigned long)classes.count, (unsigned long)methods.count);
}

static void WXKBT_DumpObjCFromBinary(NSString *binPath, NSString *tag) {
    NSData *data = [NSData dataWithContentsOfFile:binPath];
    if (data == nil) {
        NSString *msg = [NSString stringWithFormat:
            @"# FAILED to read binary\npath=%@\ntag=%@\n", binPath, tag];
        WXKBT_WriteToAllLocations([NSString stringWithFormat:@"wxkbt-objcdump-%@-ERROR.txt", tag], msg);
        return;
    }

    NSDictionary<NSString *, NSData *> *sections = WXKBT_ExtractObjCSections(data);
    if (sections != nil) {
        NSArray<NSString *> *classes = WXKBT_SplitNullStrings(sections[@"__objc_classname"]);
        NSArray<NSString *> *methods = WXKBT_SplitNullStrings(sections[@"__objc_methname"]);
        WXKBT_WriteObjCReport(binPath, tag, classes, methods,
                              @"parsed Mach-O __objc_classname/__objc_methname");
    } else {
        // Fallback: crude identifier harvest from the raw byte stream.
        NSArray<NSString *> *raw = WXKBT_RawIdentifierScan(data);
        WXKBT_WriteObjCReport(binPath, tag, raw, raw,
                              @"fallback raw identifier scan (Mach-O parse failed)");
    }
}

static void WXKBT_DumpAllWeTypeObjC(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *roots = @[
        @"/var/containers/Bundle/Application",
        @"/var/jb/var/containers/Bundle/Application",
    ];
    NSUInteger n = 0;

    for (NSString *root in roots) {
        NSArray<NSString *> *uuids = [fm contentsOfDirectoryAtPath:root error:NULL];
        if (uuids == nil) continue;
        for (NSString *uuid in uuids) {
            NSString *uuidDir = [root stringByAppendingPathComponent:uuid];
            NSArray<NSString *> *apps = [fm contentsOfDirectoryAtPath:uuidDir error:NULL];
            if (apps == nil) continue;

            for (NSString *app in apps) {
                if (![app hasSuffix:@".app"]) continue;
                NSString *appPath = [uuidDir stringByAppendingPathComponent:app];
                NSDictionary *appInfo = [NSDictionary dictionaryWithContentsOfFile:
                    [appPath stringByAppendingPathComponent:@"Info.plist"]];
                NSString *appBid = appInfo[@"CFBundleIdentifier"] ?: @"";
                BOOL isWeType =
                    ([appBid rangeOfString:@"wetype" options:NSCaseInsensitiveSearch].location != NSNotFound) ||
                    [appBid isEqualToString:@"com.tencent.wetype"];
                if (!isWeType) continue;

                // (1) main app binary
                NSString *appExec = appInfo[@"CFBundleExecutable"];
                if (appExec.length > 0) {
                    NSString *p = [appPath stringByAppendingPathComponent:appExec];
                    WXKBT_DumpObjCFromBinary(p, [NSString stringWithFormat:@"app-%@", appExec]);
                    n++;
                }

                // (2) every .appex binary under PlugIns
                NSString *plugDir = [appPath stringByAppendingPathComponent:@"PlugIns"];
                NSArray<NSString *> *plugins = [fm contentsOfDirectoryAtPath:plugDir error:NULL];
                for (NSString *pl in plugins) {
                    if (![pl hasSuffix:@".appex"]) continue;
                    NSString *plPath = [plugDir stringByAppendingPathComponent:pl];
                    NSDictionary *plInfo = [NSDictionary dictionaryWithContentsOfFile:
                        [plPath stringByAppendingPathComponent:@"Info.plist"]];
                    NSString *plExec = plInfo[@"CFBundleExecutable"];
                    if (plExec.length == 0) continue;
                    NSString *p = [plPath stringByAppendingPathComponent:plExec];
                    WXKBT_DumpObjCFromBinary(p, [NSString stringWithFormat:@"appex-%@", plExec]);
                    n++;
                }
            }
        }
    }

    NSString *summary = [NSString stringWithFormat:
        @"# wxkbt+ objc dump run\npid=%d\ndumped binaries: %lu\n"
        @"# files: /var/mobile/Documents/wxkbt-objcdump-*.txt\n"
        @"# also mirrored in /tmp/\n", getpid(), (unsigned long)n];
    WXKBT_WriteToAllLocations(@"wxkbt-objcdump-SUMMARY.txt", summary);
    NSLog(@"[WXKBT+] objc dump run complete: %lu binaries", (unsigned long)n);
}

// ---------------------------------------------------------------------------
// Runtime class/method dump — only meaningful once the tweak actually loads
// inside the WeType keyboard extension / main app. Enumerates every loaded
// class whose name mentions ToolBar/Toolbar and dumps its full method list,
// so we can see exactly which class owns saveToolbarFuncs:, maxCount, etc.
// ---------------------------------------------------------------------------
static void WXKBT_DumpRuntimeToolbarClasses(void) {
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (classes == NULL) return;

    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"# wxkbt+ runtime toolbar class dump\n"];
    [out appendFormat:@"pid=%d\n", getpid()];
    [out appendFormat:@"bundle=%s\n", [[[NSBundle mainBundle] bundleIdentifier] UTF8String] ?: "nil"];
    [out appendFormat:@"exec=%s\n", [[[NSBundle mainBundle] executablePath] UTF8String] ?: "nil"];
    [out appendFormat:@"loaded classes=%u\n\n", count];

    // ---- Part 1: reverse index for the selectors we care about most ----
    NSArray<NSString *> *probeSels = @[
        @"canSetToolbarFunc:enabled:", @"setToolbarFunc:enabled:",
        @"setToolBarFunc:enabled:", @"setToolBarFunc:toolbarFuncs:enabled:",
        @"setToolbarFuncs:", @"setToolbarFuncs:source:",
        @"updateToolbarFuns:source:", @"isToolbarFuncEnabled:",
        @"isToolbarDisplayingFunc:", @"needShowInToolBar",
        @"saveToolbarFuncs:editingSource:", @"setEdittingToolBarFunc:enabled:removeFromRecent:",
        @"updateEdittingToolbarFuncs:", @"toolbarFuncsForScene:suggestedTypes:prefersRecent:",
        @"toolbarFuncsForScene:", @"updateToolBarItems", @"updateToolBarIcons",
        @"initToolBarPanel", @"initToolBarIfNeeded", @"initCustomToolBarIfNeeded",
        @"handleToolBarFuncEvent:suggestedType:controlEvent:",
        @"toolBar:requireChangeExpandState:", @"setToolBarShrunken:animated:"
    ];

    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *index =
        [NSMutableDictionary dictionary];
    for (NSString *s in probeSels) index[s] = [NSMutableArray array];

    NSMutableString *classSection = [NSMutableString string];
    NSUInteger toolbarish = 0;

    for (unsigned int i = 0; i < count; i++) {
        const char *cn = class_getName(classes[i]);
        if (cn == NULL) continue;
        NSString *name = [NSString stringWithUTF8String:cn];
        if (name == nil) continue;

        unsigned int mcount = 0;
        Method *ms = class_copyMethodList(classes[i], &mcount);
        if (ms == NULL) continue;

        // feed the reverse index
        for (unsigned int j = 0; j < mcount; j++) {
            SEL sel = method_getName(ms[j]);
            if (sel == NULL) continue;
            NSString *selName = [NSString stringWithUTF8String:sel_getName(sel)];
            NSMutableArray *bucket = index[selName];
            if (bucket != nil) [bucket addObject:name];
        }

        // full method list for toolbar-ish classes
        BOOL interesting =
            [name rangeOfString:@"ToolBar" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [name rangeOfString:@"Toolbar" options:NSCaseInsensitiveSearch].location != NSNotFound;
        if (interesting) {
            toolbarish++;
            [classSection appendFormat:@"=== %@ ===\n", name];
            for (unsigned int j = 0; j < mcount; j++) {
                SEL sel = method_getName(ms[j]);
                if (sel == NULL) continue;
                [classSection appendFormat:@"  -%s\n", sel_getName(sel)];
            }
            [classSection appendString:@"\n"];
        }
        free(ms);
    }
    free(classes);

    // ---- Part 2: emit reverse index first (most useful) ----
    [out appendString:@"===== REVERSE INDEX (selector -> classes that implement it) =====\n\n"];
    for (NSString *s in probeSels) {
        NSArray *bucket = index[s];
        [out appendFormat:@"[%@] (%lu)\n", s, (unsigned long)bucket.count];
        for (NSString *cn in bucket) [out appendFormat:@"    %@\n", cn];
        [out appendString:@"\n"];
    }

    // ---- Part 3: full method lists ----
    [out appendFormat:@"\n===== TOOLBAR CLASS METHOD LISTS (%lu classes) =====\n\n",
        (unsigned long)toolbarish];
    [out appendString:classSection];

    NSString *basename = [NSString stringWithFormat:@"wxkbt-runtime-toolbar-%d.txt", getpid()];
    WXKBT_WriteToAllLocations(basename, out);
    NSLog(@"[WXKBT+] runtime toolbar dump: %lu classes -> %@",
          (unsigned long)toolbarish, basename);
}