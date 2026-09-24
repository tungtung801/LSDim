/*
 * 26LockDim 0.1.3
 *
 * Lock Screen notification background dimming, kept separate from 26Unlock.
 * The tweak observes the live CoverSheet hierarchy and writes only a black
 * background layer below the notification branch and clock branch. It does not
 * change system brightness, notification alpha, the clock, or the unlock state machine.
 */

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <math.h>
#import <stdio.h>
#import <stdlib.h>
#import <stdint.h>

#define LD_SETTINGS @"/var/mobile/26LockDim.plist"
#define LD_LOGFILE  "/var/mobile/26LockDim.log"
#define LD_SAFEFILE @"/var/mobile/Media/26LockDim.safe"

static BOOL  g_enabled     = YES;
static BOOL  g_debug       = YES;
static BOOL  g_stickyClock = YES;
static float g_maxAlpha    = 0.48f;

static __weak UIViewController *g_coverController;
static __weak UIView *g_coverRoot;
static __weak UIScrollView *g_notificationScroll;
static __weak UIView *g_clockBranch;
static __weak UIView *g_overlayHost;
static UIView *g_overlay;
static CADisplayLink *g_displayLink;
static NSObject *g_displayTarget;

static BOOL    g_active;
static BOOL    g_safeMode;
static BOOL    g_markerArmed;
static uint64_t g_safetyGeneration;
static BOOL    g_baselineReady;
static CGRect  g_baseRect;
static CGFloat g_baseOffsetY;
static CGSize  g_baseRootSize;
static CGRect  g_baseClockBranchFrame;
static CGFloat g_baseClockTopInRoot;
static BOOL    g_clockBaselineReady;
static CGFloat g_alpha;
static CGFloat g_progress;
static CFTimeInterval g_lastFrame;
static CFTimeInterval g_lastLog;

static float ld_clampf(float value, float lo, float hi) {
    return fminf(fmaxf(value, lo), hi);
}

static float ld_smoothstep(float x) {
    x = ld_clampf(x, 0.0f, 1.0f);
    return x * x * (3.0f - 2.0f * x);
}

static void ld_log(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void ld_log(NSString *format, ...) {
    if (!g_debug) return;

    va_list ap;
    va_start(ap, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:ap];
    va_end(ap);

    NSLog(@"[26LockDim] %@", message);

    @autoreleasepool {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSDictionary *attrs = [fm attributesOfItemAtPath:@LD_LOGFILE error:NULL];
        if (attrs && [attrs fileSize] > 200 * 1024)
            [fm removeItemAtPath:@LD_LOGFILE error:NULL];

        NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], message];
        FILE *file = fopen(LD_LOGFILE, "a");
        if (file) {
            fputs([line UTF8String], file);
            fclose(file);
        }
    }
}

static void ld_readSettings(void) {
    NSDictionary *settings = [NSDictionary dictionaryWithContentsOfFile:LD_SETTINGS];
    if (!settings) return;

    id value = settings[@"enabled"];
    if ([value isKindOfClass:[NSNumber class]]) g_enabled = [value boolValue];

    value = settings[@"debug"];
    if ([value isKindOfClass:[NSNumber class]]) g_debug = [value boolValue];

    value = settings[@"stickyClock"];
    if ([value isKindOfClass:[NSNumber class]]) g_stickyClock = [value boolValue];

    value = settings[@"maxAlpha"];
    if ([value isKindOfClass:[NSNumber class]])
        g_maxAlpha = ld_clampf([value floatValue], 0.0f, 0.85f);
}

static void ld_clearSafetyMarker(void) {
    g_safetyGeneration++;
    g_markerArmed = NO;
    [[NSFileManager defaultManager] removeItemAtPath:LD_SAFEFILE error:NULL];
}

static void ld_armSafetyWindow(NSString *reason) {
    if (g_safeMode) return;

    g_safetyGeneration++;
    g_markerArmed = YES;
    NSDictionary *marker = @{
        @"reason": reason ?: @"unknown",
        @"time": @([[NSDate date] timeIntervalSince1970])
    };
    [marker writeToFile:LD_SAFEFILE atomically:YES];

    uint64_t generation = g_safetyGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (g_safeMode || generation != g_safetyGeneration) return;
        ld_clearSafetyMarker();
    });
}

static void ld_checkSafetyMarker(void) {
    if ([[NSFileManager defaultManager] fileExistsAtPath:LD_SAFEFILE]) {
        g_safeMode = YES;
        NSLog(@"[26LockDim] safe mode: %@ exists; no hooks installed", LD_SAFEFILE);
    }
}

static NSString *ld_className(id object) {
    return object ? NSStringFromClass([object class]) : @"";
}

static BOOL ld_isDescendant(UIView *view, UIView *root) {
    if (!view || !root) return NO;
    if (view == root) return YES;
    return [view isDescendantOfView:root];
}

/* Find the scroll surface that represents the Lock Screen notification list.
 * The class names changed between iOS 15 and 16, so use names only as a
 * positive score and retain a geometry/content fallback. */
static void ld_findNotificationScroll(UIView *view, UIView *root,
                                      UIScrollView **best, CGFloat *bestScore,
                                      int depth) {
    if (!view || !root || depth > 14) return;

    if ([view isKindOfClass:[UIScrollView class]]) {
        UIScrollView *scroll = (UIScrollView *)view;
        CGRect rect = CGRectZero;
        @try {
            rect = [scroll convertRect:scroll.bounds toView:root];
        } @catch (NSException *exception) {
            rect = CGRectZero;
        }

        CGFloat rootArea = fmax(1.0, root.bounds.size.width * root.bounds.size.height);
        CGFloat area = fmax(0.0, rect.size.width * rect.size.height);
        NSString *name = [ld_className(scroll) lowercaseString];
        BOOL namedNotification = [name containsString:@"notification"] ||
                                 [name containsString:@"combinedlist"] ||
                                 [name containsString:@"bulletin"] ||
                                 [name containsString:@"coverlist"];
        BOOL blocked = [name containsString:@"widget"] ||
                       [name containsString:@"media"] ||
                       [name containsString:@"keyboard"] ||
                       [name containsString:@"quickaction"];
        BOOL verticallyScrollable = scroll.contentSize.height >
                                     scroll.bounds.size.height + 10.0;
        BOOL screenLike = rect.size.width >= root.bounds.size.width * 0.42 &&
                          rect.size.height >= root.bounds.size.height * 0.18;

        if (!blocked && screenLike && (namedNotification || verticallyScrollable)) {
            CGFloat score = area / rootArea * 50.0;
            if (namedNotification) score += 100.0;
            if (verticallyScrollable) score += 25.0;
            if (rect.size.width >= root.bounds.size.width * 0.75) score += 10.0;
            if (rect.size.height >= root.bounds.size.height * 0.45) score += 10.0;
            if (score > *bestScore) {
                *best = scroll;
                *bestScore = score;
            }
        }
    }

    for (UIView *subview in view.subviews)
        ld_findNotificationScroll(subview, root, best, bestScore, depth + 1);
}

static UIScrollView *ld_notificationScrollForRoot(UIView *root) {
    if (!root) return nil;
    UIScrollView *best = nil;
    CGFloat bestScore = 0.0;
    ld_findNotificationScroll(root, root, &best, &bestScore, 0);
    return best;
}

static BOOL ld_scrollHasNotifications(UIScrollView *scroll) {
    if (!scroll) return NO;
    if (scroll.contentSize.height > scroll.bounds.size.height + 10.0) return YES;

    NSString *name = [[ld_className(scroll) lowercaseString] copy];
    if ([name containsString:@"notification"] && scroll.subviews.count > 0)
        return YES;
    return NO;
}

static void ld_findClockView(UIView *view, UIView **best, int depth) {
    if (!view || depth > 14 || *best) return;

    NSString *name = ld_className(view);
    if ([name isEqualToString:@"CSProminentTimeView"] ||
        [name isEqualToString:@"CSProminentDisplayView"] ||
        [name isEqualToString:@"SBFLockScreenDateView"]) {
        *best = view;
        return;
    }

    if ([name containsString:@"ProminentTime"] ||
        [name containsString:@"LockScreenDateView"]) {
        *best = view;
        return;
    }

    for (UIView *subview in view.subviews) {
        ld_findClockView(subview, best, depth + 1);
        if (*best) return;
    }
}

static UIView *ld_findClockViewInTree(UIView *view) {
    UIView *best = nil;
    ld_findClockView(view, &best, 0);
    return best;
}

static UIView *ld_clockBranchForRoot(UIView *root) {
    if (!root) return nil;

    UIView *clockView = nil;
    @try {
        if (g_coverController && [g_coverController respondsToSelector:@selector(dateViewController)]) {
            UIViewController *dvc = [g_coverController valueForKey:@"dateViewController"];
            if (dvc && dvc.view) clockView = dvc.view;
        }
        if (!clockView && [root respondsToSelector:@selector(dateView)]) {
            UIView *dv = [root valueForKey:@"dateView"];
            if (dv) clockView = dv;
        }
    } @catch (NSException *e) {
    }

    if (!clockView) {
        clockView = ld_findClockViewInTree(root);
    }

    if (!clockView) return nil;

    UIView *branch = clockView;
    while (branch.superview && branch.superview != root)
        branch = branch.superview;

    if (branch.superview == root) return branch;
    return nil;
}

static void ld_captureBaseline(UIScrollView *scroll, UIView *root) {
    if (!scroll || !root) return;
    @try {
        g_baseRect = [scroll convertRect:scroll.bounds toView:root];
    } @catch (NSException *exception) {
        g_baseRect = scroll.frame;
    }
    g_baseOffsetY = scroll.contentOffset.y;
    g_baseRootSize = root.bounds.size;
    g_baselineReady = YES;

    // Capture clock baseline
    UIView *clockBranch = g_clockBranch;
    if (!clockBranch || clockBranch.superview != root) {
        clockBranch = ld_clockBranchForRoot(root);
        g_clockBranch = clockBranch;
    }
    if (clockBranch && clockBranch.superview == root) {
        g_baseClockBranchFrame = clockBranch.frame;
        UIView *clockView = ld_findClockViewInTree(clockBranch);
        if (clockView) {
            @try {
                CGRect r = [clockView convertRect:clockView.bounds toView:root];
                g_baseClockTopInRoot = r.origin.y;
                g_clockBaselineReady = YES;
            } @catch (NSException *e) {
                g_baseClockTopInRoot = clockBranch.frame.origin.y;
                g_clockBaselineReady = YES;
            }
        } else {
            g_baseClockTopInRoot = clockBranch.frame.origin.y;
            g_clockBaselineReady = YES;
        }
    }

    ld_log(@"baseline scroll=%@ rect=%@ offsetY=%.2f root=%@ clockBranch=%@ top=%.1f",
           ld_className(scroll), NSStringFromCGRect(g_baseRect),
           g_baseOffsetY, NSStringFromClass([root class]),
           NSStringFromCGRect(g_baseClockBranchFrame), g_baseClockTopInRoot);
}

/* Put the overlay in the full-screen ancestor immediately below both the direct
 * branch containing notifications and the branch containing the clock / time view.
 * This leaves the notification branch and clock branch above the black layer
 * while dimming wallpaper/background siblings below it. */
static void ld_attachOverlay(UIView *root, UIScrollView *scroll) {
    if (!root || !scroll) return;

    UIView *branch = scroll;
    while (branch.superview && branch.superview != root)
        branch = branch.superview;

    if (!branch.superview && branch != root) return;

    UIView *host = root;

    UIView *clockBranch = g_clockBranch;
    if (!clockBranch || clockBranch.superview != host) {
        clockBranch = ld_clockBranchForRoot(host);
        g_clockBranch = clockBranch;
    }
    if (clockBranch == branch) {
        clockBranch = nil;
    }

    if (!g_overlay) {
        g_overlay = [[UIView alloc] initWithFrame:root.bounds];
        g_overlay.backgroundColor = [UIColor blackColor];
        g_overlay.userInteractionEnabled = NO;
        g_overlay.accessibilityElementsHidden = YES;
        g_overlay.layer.zPosition = 0.0;
    }

    NSUInteger oldIndex = g_overlay.superview == host ? [host.subviews indexOfObject:g_overlay] : NSNotFound;
    NSUInteger clockIndex = (clockBranch && clockBranch.superview == host)
        ? [host.subviews indexOfObject:clockBranch]
        : NSNotFound;
    NSUInteger branchIndex = [host.subviews indexOfObject:branch];

    NSUInteger targetUpperIndex = branchIndex;
    if (clockIndex != NSNotFound && clockIndex < targetUpperIndex) {
        targetUpperIndex = clockIndex;
    }

    BOOL alreadyPositioned = (oldIndex != NSNotFound &&
                              targetUpperIndex != NSNotFound &&
                              oldIndex + 1 == targetUpperIndex);

    if (g_overlay.superview != host || !alreadyPositioned) {
        [g_overlay removeFromSuperview];

        NSUInteger freshClockIndex = (clockBranch && clockBranch.superview == host)
            ? [host.subviews indexOfObject:clockBranch]
            : NSNotFound;
        NSUInteger freshBranchIndex = [host.subviews indexOfObject:branch];

        NSUInteger insertIndex = freshBranchIndex;
        if (freshClockIndex != NSNotFound && freshClockIndex < insertIndex) {
            insertIndex = freshClockIndex;
        }
        if (insertIndex == NSNotFound) insertIndex = 0;

        [host insertSubview:g_overlay atIndex:insertIndex];

        if (g_lastLog == 0.0 || g_debug) {
            ld_log(@"overlay host=%@ insertIndex=%lu (clock=%@ idx=%lu, notif=%@ idx=%lu)",
                   ld_className(host), (unsigned long)insertIndex,
                   ld_className(clockBranch), (unsigned long)freshClockIndex,
                   ld_className(branch), (unsigned long)freshBranchIndex);
        }
    }

    g_overlay.frame = host.bounds;
    g_overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                 UIViewAutoresizingFlexibleHeight;
    g_overlayHost = host;
}

static void ld_scanPanProgress(UIView *view, UIView *root, CGFloat *progress,
                               int depth) {
    if (!view || !root || !progress || depth > 14) return;

    for (UIGestureRecognizer *gesture in view.gestureRecognizers) {
        if (![gesture isKindOfClass:[UIPanGestureRecognizer class]]) continue;
        if (gesture.state != UIGestureRecognizerStateBegan &&
            gesture.state != UIGestureRecognizerStateChanged) continue;

        UIPanGestureRecognizer *pan = (UIPanGestureRecognizer *)gesture;
        CGPoint translation = [pan translationInView:root];
        CGPoint velocity = [pan velocityInView:root];
        if (translation.y < -2.0 || velocity.y < -80.0) {
            CGFloat travel = fmax(80.0, root.bounds.size.height * 0.28);
            CGFloat p = ld_clampf((float)(-translation.y / travel), 0.0f, 1.0f);
            if (p > *progress) *progress = p;
        }
    }

    for (UIView *subview in view.subviews)
        ld_scanPanProgress(subview, root, progress, depth + 1);
}

static CGFloat ld_progressForScroll(UIScrollView *scroll, UIView *root) {
    if (!scroll || !root || !g_baselineReady) return 0.0f;

    if (fabs(root.bounds.size.width - g_baseRootSize.width) > 30.0 ||
        fabs(root.bounds.size.height - g_baseRootSize.height) > 30.0) {
        ld_captureBaseline(scroll, root);
        return 0.0f;
    }

    CGRect currentRect = CGRectZero;
    @try {
        currentRect = [scroll convertRect:scroll.bounds toView:root];
    } @catch (NSException *exception) {
        currentRect = scroll.frame;
    }

    CGFloat rootHeight = fmax(1.0, root.bounds.size.height);
    CGFloat upwardMove = g_baseRect.origin.y - currentRect.origin.y;
    CGFloat pFrame = ld_clampf((float)(upwardMove / fmax(80.0, rootHeight * 0.24)),
                                0.0f, 1.0f);

    CGFloat offsetDelta = fabs(scroll.contentOffset.y - g_baseOffsetY);
    CGFloat maxOffset = fmax(0.0, scroll.contentSize.height - scroll.bounds.size.height);
    CGFloat offsetTravel = fmax(80.0, fmin(rootHeight * 0.65, maxOffset));
    CGFloat pOffset = maxOffset > 1.0
        ? ld_clampf((float)(offsetDelta / offsetTravel), 0.0f, 1.0f)
        : 0.0f;

    CGFloat pPan = 0.0f;
    ld_scanPanProgress(root, root, &pPan, 0);

    /* The maximum keeps the overlay attached to whichever live geometry the
     * current iOS build exposes: moving CoverSheet frame, scroll offset, or
     * the active pan itself. */
    return fmax(pFrame, fmax(pOffset, pPan));
}

static void ld_setActive(BOOL active) {
    g_active = active;
    g_baselineReady = NO;
    g_clockBaselineReady = NO;
    g_notificationScroll = nil;
    g_clockBranch = nil;
    g_baseClockBranchFrame = CGRectZero;
    g_baseClockTopInRoot = 0.0f;
    g_progress = 0.0f;
    g_alpha = 0.0f;
    g_lastFrame = 0.0;
    g_lastLog = 0.0;

    if (!active) {
        [g_displayLink invalidate];
        g_displayLink = nil;
        g_displayTarget = nil;
        [g_overlay removeFromSuperview];
        g_overlay = nil;
        g_overlayHost = nil;
        g_clockBranch = nil;
        return;
    }

}

static void ld_tick(CADisplayLink *link);
static void ld_tick_impl(CADisplayLink *link);

@interface LDDisplayTarget : NSObject
@end

@implementation LDDisplayTarget
- (void)ld_tick:(CADisplayLink *)link {
    ld_tick(link);
}
@end

static void ld_start(UIViewController *controller) {
    ld_readSettings();
    if (g_safeMode || !g_enabled) return;

    ld_armSafetyWindow(@"cover");
    g_coverController = controller;
    g_coverRoot = controller.view;
    ld_setActive(g_enabled);
    if (!g_enabled) return;

    if (!g_displayLink) {
        g_displayTarget = [LDDisplayTarget new];
        g_displayLink = [CADisplayLink displayLinkWithTarget:g_displayTarget
                                                    selector:@selector(ld_tick:)];
        g_displayLink.preferredFramesPerSecond = 60;
        [g_displayLink addToRunLoop:[NSRunLoop mainRunLoop]
                             forMode:NSRunLoopCommonModes];
    }
    ld_log(@"cover start root=%@", ld_className(g_coverRoot));
}

static void ld_stopIfController(id object) {
    UIViewController *controller = (UIViewController *)object;
    if (g_coverController && controller != g_coverController) return;
    ld_log(@"cover stop");
    g_coverController = nil;
    g_coverRoot = nil;
    ld_setActive(NO);
    if (!g_safeMode) ld_clearSafetyMarker();
}

static void ld_tick_impl(CADisplayLink *link) {
    if (!g_active) return;
    ld_readSettings();
    if (!g_enabled) {
        ld_setActive(NO);
        return;
    }

    UIView *root = g_coverRoot;
    if (!root || !root.window) {
        ld_stopIfController(g_coverController);
        return;
    }

    CFTimeInterval now = CACurrentMediaTime();
    CFTimeInterval dt = g_lastFrame > 0.0 ? now - g_lastFrame : 1.0 / 60.0;
    g_lastFrame = now;
    dt = fmin(0.10, fmax(0.001, dt));

    UIScrollView *scroll = g_notificationScroll;
    if (!ld_isDescendant(scroll, root)) scroll = nil;
    if (!scroll) scroll = ld_notificationScrollForRoot(root);

    CGFloat targetProgress = 0.0f;
    if (scroll && ld_scrollHasNotifications(scroll)) {
        if (scroll != g_notificationScroll || !g_baselineReady) {
            g_notificationScroll = scroll;
            ld_captureBaseline(scroll, root);
        }
        ld_attachOverlay(root, scroll);
        targetProgress = ld_progressForScroll(scroll, root);
    }

    g_progress += (targetProgress - g_progress) *
                  (1.0f - expf((float)(-dt / 0.045f)));
    g_progress = ld_clampf(g_progress, 0.0f, 1.0f);

    CGFloat targetAlpha = g_maxAlpha * ld_smoothstep(g_progress);
    g_alpha += (targetAlpha - g_alpha) *
               (1.0f - expf((float)(-dt / 0.055f)));
    g_alpha = ld_clampf(g_alpha, 0.0f, g_maxAlpha);

    if (g_overlay) {
        g_overlay.hidden = (g_alpha < 0.001f);
        g_overlay.alpha = g_alpha;
    }

    if (g_stickyClock && g_clockBaselineReady) {
        UIView *clockBranch = g_clockBranch;
        if (clockBranch && clockBranch.superview == root) {
            if (!CGRectEqualToRect(g_baseClockBranchFrame, CGRectZero)) {
                CGRect bf = clockBranch.frame;
                if (fabs(bf.origin.y - g_baseClockBranchFrame.origin.y) > 0.5) {
                    bf.origin.y = g_baseClockBranchFrame.origin.y;
                    clockBranch.frame = bf;
                }
                if (fabs(bf.origin.x - g_baseClockBranchFrame.origin.x) > 0.5) {
                    bf.origin.x = g_baseClockBranchFrame.origin.x;
                    clockBranch.frame = bf;
                }
            }

            UIView *clockView = ld_findClockViewInTree(clockBranch);
            if (clockView) {
                @try {
                    CGRect curRect = [clockView convertRect:clockView.bounds toView:root];
                    CGFloat diffY = g_baseClockTopInRoot - curRect.origin.y;
                    if (fabs(diffY) > 0.5) {
                        CGAffineTransform t = clockView.transform;
                        clockView.transform = CGAffineTransformTranslate(t, 0.0, diffY);
                    }
                } @catch (NSException *e) {
                }
            }
        }
    }

    if (g_debug && now - g_lastLog > 0.20) {
        g_lastLog = now;
        ld_log(@"scroll=%@ progress=%.3f alpha=%.3f target=%.3f offsetY=%.2f frameY=%.1f",
               ld_className(scroll), g_progress, g_alpha, targetProgress,
               scroll ? scroll.contentOffset.y : 0.0,
               scroll ? scroll.frame.origin.y : 0.0);
    }
}

static void ld_tick(CADisplayLink *link) {
    @try {
        ld_tick_impl(link);
    } @catch (NSException *exception) {
        /* A private hierarchy can throw on an OS point release.  Fail closed
         * instead of allowing the display-link callback to unwind into
         * SpringBoard.  The marker remains for the next-launch safe mode. */
        NSLog(@"[26LockDim] disabling after exception: %@", exception);
        g_enabled = NO;
        ld_setActive(NO);
    }
}

/* Superclass-safe runtime swizzle. */
static IMP ld_swizzle(Class cls, SEL selector, IMP replacement) {
    if (!cls || !selector || !replacement) return NULL;

    Method own = NULL;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == selector) {
            own = methods[i];
            break;
        }
    }
    free(methods);

    if (own) {
        IMP original = method_getImplementation(own);
        method_setImplementation(own, replacement);
        return original;
    }

    Class super = class_getSuperclass(cls);
    Method inherited = super ? class_getInstanceMethod(super, selector) : NULL;
    if (!inherited) return NULL;

    IMP original = method_getImplementation(inherited);
    if (!class_addMethod(cls, selector, replacement,
                         method_getTypeEncoding(inherited))) return NULL;
    return original;
}

typedef void (*LDViewAppearFn)(id, SEL, BOOL);
typedef void (*LDLayoutDateViewFn)(id, SEL);

static IMP g_origCSAppear;
static IMP g_origCSDisappear;
static IMP g_origSBAppear;
static IMP g_origSBDisappear;
static IMP g_origCSLayoutDateView;

static void ld_csLayoutDateView(id self, SEL selector) {
    if (g_origCSLayoutDateView) ((LDLayoutDateViewFn)g_origCSLayoutDateView)(self, selector);
    if (g_enabled && g_stickyClock && g_clockBaselineReady &&
        !CGRectEqualToRect(g_baseClockBranchFrame, CGRectZero)) {
        UIView *clockBranch = g_clockBranch;
        if (clockBranch && clockBranch.superview == (UIView *)self) {
            CGRect f = clockBranch.frame;
            f.origin.y = g_baseClockBranchFrame.origin.y;
            clockBranch.frame = f;
        }
    }
}

static void ld_csViewWillAppear(id self, SEL selector, BOOL animated) {
    if (g_origCSAppear) ((LDViewAppearFn)g_origCSAppear)(self, selector, animated);
    @try {
        ld_start((UIViewController *)self);
    } @catch (NSException *exception) {
        NSLog(@"[26LockDim] start exception: %@", exception);
        g_enabled = NO;
        ld_setActive(NO);
    }
}

static void ld_csViewDidDisappear(id self, SEL selector, BOOL animated) {
    if (g_origCSDisappear) ((LDViewAppearFn)g_origCSDisappear)(self, selector, animated);
    ld_stopIfController(self);
}

static void ld_sbViewWillAppear(id self, SEL selector, BOOL animated) {
    if (g_origSBAppear) ((LDViewAppearFn)g_origSBAppear)(self, selector, animated);
    @try {
        ld_start((UIViewController *)self);
    } @catch (NSException *exception) {
        NSLog(@"[26LockDim] start exception: %@", exception);
        g_enabled = NO;
        ld_setActive(NO);
    }
}

static void ld_sbViewDidDisappear(id self, SEL selector, BOOL animated) {
    if (g_origSBDisappear) ((LDViewAppearFn)g_origSBDisappear)(self, selector, animated);
    ld_stopIfController(self);
}

__attribute__((constructor))
static void ld_init(void) {
    @autoreleasepool {
        ld_readSettings();
        ld_checkSafetyMarker();
        if (g_safeMode || !g_enabled) {
            ld_log(@"not installing hooks safe=%d enabled=%d", g_safeMode, g_enabled);
            return;
        }
        ld_armSafetyWindow(@"constructor");

        Class cs = NSClassFromString(@"CSCoverSheetViewController");
        Class sb = NSClassFromString(@"SBCoverSheetViewController");
        Class csView = NSClassFromString(@"CSCoverSheetView");
        if (cs) {
            g_origCSAppear = ld_swizzle(cs, @selector(viewWillAppear:),
                                        (IMP)ld_csViewWillAppear);
            g_origCSDisappear = ld_swizzle(cs, @selector(viewDidDisappear:),
                                           (IMP)ld_csViewDidDisappear);
        }
        if (sb) {
            g_origSBAppear = ld_swizzle(sb, @selector(viewWillAppear:),
                                        (IMP)ld_sbViewWillAppear);
            g_origSBDisappear = ld_swizzle(sb, @selector(viewDidDisappear:),
                                           (IMP)ld_sbViewDidDisappear);
        }
        if (csView) {
            g_origCSLayoutDateView = ld_swizzle(csView, @selector(_layoutDateView),
                                                (IMP)ld_csLayoutDateView);
        }

        ld_log(@"loaded enabled=%d sticky=%d maxAlpha=%.2f CS=%@ SB=%@ CSView=%@",
               g_enabled, g_stickyClock, g_maxAlpha,
               cs ? NSStringFromClass(cs) : @"missing",
               sb ? NSStringFromClass(sb) : @"missing",
               csView ? NSStringFromClass(csView) : @"missing");
    }
}
