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

%ctor {
    NSLog(@"[WXKBT+] tweak loaded in pid=%d (domain=%@).",
          getpid(), kPrefDomain);

    Class cls = objc_getClass("WXKeyboardToolbarView");
    if (cls == NULL) {
        NSLog(@"[WXKBT+] FATAL: WXKeyboardToolbarView not found. "
               "Dumping candidate classes per pid.");
        WXKBT_WriteBootInfo("class-not-found");
        WXKBT_DumpClassesToFile();
        return;
    }
    NSLog(@"[WXKBT+] hooked (bin=%s, domain=%@).",
          class_getName(cls), kPrefDomain);
    WXKBT_WriteBootInfo(class_getName(cls));
}

// Always-on boot marker: writes a per-pid file under
// /var/mobile/Documents/wxkbt-info-<pid>.txt so we can tell which processes
// the tweak actually loaded into (regardless of whether WXKeyboardToolbarView
// was found). The user pulls these via Filza.
static void WXKBT_WriteBootInfo(const char *status) {
    NSString *path = [NSString stringWithFormat:@"/var/mobile/Documents/wxkbt-info-%d.txt", getpid()];
    NSMutableString *info = [NSMutableString string];
    [info appendFormat:@"pid=%d\n", getpid()];
    [info appendFormat:@"status=%s\n", status];
    [info appendFormat:@"main_bundle=%s\n", [[[NSBundle mainBundle] bundleIdentifier] UTF8String] ?: "nil"];
    [info appendFormat:@"main_exec=%s\n", [[[NSBundle mainBundle] executablePath] UTF8String] ?: "nil"];
    NSString *err = nil;
    NSError *writeErr = nil;
    [info writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&writeErr];
    NSLog(@"[WXKBT+] boot info written -> %@", path);
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

    NSString *path = [NSString stringWithFormat:@"/var/mobile/Documents/wxkbt-classes-%d.txt", getpid()];
    NSError *err = nil;
    BOOL ok = [report writeToFile:path
                       atomically:YES
                         encoding:NSUTF8StringEncoding
                            error:&err];
    NSLog(@"[WXKBT+] class dump %@ (%lu lines) -> %@",
          ok ? @"written" : @"FAILED",
          (unsigned long)seen.count,
          path);
}