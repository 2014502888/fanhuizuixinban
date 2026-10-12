// ============================================================================
//  FullScreenBackUniversal.m  —  通用全屏返回（合并版 v1）
//  Universal Full-Screen Swipe-Back  ·  plain Objective-C · 注入任意 App
// ============================================================================
//  合并来源：
//    · FullScreenBack (tweak/FullScreenBack.x + plain/FullScreenBack.m)
//        —— 左边缘让位 / 反向转场 / 触觉反馈 / 转场忙判断 / 多路径 target /
//           横滚 ScrollView 让位 / 媒体查看器排除
//    · iOSFullScreenBackTweak（本机已真机验证的极简版）
//        —— 全 @try 崩溃防护（私有结构变了最多不生效，绝不闪退）
//  合并修正：
//    · 修复 x 版 FSBFallbackProxy 野指针：代理对象由 static 全局强持有，
//      addTarget 的弱引用不会再指向已释放对象
//    · 无 NSUserDefaults 配置项：行为全部写死（震动默认开）
//    · 手势转发器：松手时走公开 API popViewControllerAnimated:，
//      不转发系统私有交互式转场方法（私有转场在 Flutter/混合栈重入会卡死）
//  编译（clang / Xcode，GitHub Actions 用）：
//      xcrun -sdk iphoneos clang -arch arm64 -dynamiclib -O2 -fobjc-arc \
//          -framework UIKit -framework Foundation \
//          -Wno-undeclared-selector -mios-version-min=15.0 \
//          -o FullScreenBackUniversal.dylib plain/FullScreenBackUniversal.m \
//          -install_name @rpath/FullScreenBackUniversal.dylib
//  最低系统：iOS 15.0（arm64；arm64e 设备原生兼容 arm64）
// ============================================================================

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <math.h>

// ============================== 1. 写死常量 =================================
static const CGFloat kFSBDistance = 0.30f;    // 松手判定：拖过屏幕宽度 30% 才返回
static const CGFloat kFSBLeftZone = 22.0f;    // 左边缘让位宽度(pt)，让给系统原生边缘手势
static const CGFloat kFSBStrength = 0.8f;     // 确认震动力度 0~1
static const CGFloat kFSBFastVel  = 320.0f;   // 快速滑动速度阈值 (pt/s)
static const CGFloat kFSBFastMinX = 8.0f;     // 快速滑动最小位移 (pt)
// 震动：默认开（无开关）

// ============================== 2. 触觉反馈 =================================
@interface FSBHaptics : NSObject
+ (instancetype)shared;
- (void)trackGesture:(UIPanGestureRecognizer *)g;
@end

@implementation FSBHaptics {
    UIImpactFeedbackGenerator    *_heavy;
    UISelectionFeedbackGenerator *_light;
    BOOL _crossed;
}
+ (instancetype)shared {
    static FSBHaptics *s; static dispatch_once_t t;
    dispatch_once(&t, ^{ s = [FSBHaptics new]; });
    return s;
}
- (void)trackGesture:(UIPanGestureRecognizer *)g {
    @try {
        switch (g.state) {
            case UIGestureRecognizerStateBegan:
                _heavy = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
                [_heavy prepare];
                _light = [UISelectionFeedbackGenerator new];
                [_light prepare];
                _crossed = NO;
                break;
            case UIGestureRecognizerStateChanged: {
                UIView *host = g.view;
                CGFloat w = host ? host.bounds.size.width : 0.0;
                if (w <= 0.0) break;
                CGFloat x = [g translationInView:host].x;
                if (x >= w * kFSBDistance) {
                    if (!_crossed) { _crossed = YES; [_light selectionChanged]; }
                } else {
                    _crossed = NO;
                }
                break;
            }
            case UIGestureRecognizerStateEnded: {
                UIView *host = g.view;
                CGFloat w = host ? host.bounds.size.width : 0.0;
                CGPoint tr  = [g translationInView:host];
                CGPoint vel = [g velocityInView:host];
                BOOL passed = (w > 0.0 && tr.x > w * kFSBDistance) ||
                              (vel.x > kFSBFastVel && tr.x > kFSBFastMinX);
                if (passed) {
                    UIImpactFeedbackGenerator *gen =
                        [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
                    [gen impactOccurredWithIntensity:kFSBStrength];
                }
                _heavy = nil; _light = nil; _crossed = NO;
                break;
            }
            default:
                _heavy = nil; _light = nil; _crossed = NO;
                break;
        }
    } @catch (id e) {}
}
@end

// ============================== 3. 手势子类 =================================
// 独立子类标记我们自己的手势，幂等判断用（不重复安装）
@interface FSBFullScreenPan : UIPanGestureRecognizer
@end
@implementation FSBFullScreenPan
@end

// ============================== 4. 工具函数 =================================
// 顺 responder 链找导航控制器
static UINavigationController *FSBNavForView(UIView *v) {
    @try {
        UIResponder *r = v;
        while (r) {
            if ([r isKindOfClass:[UINavigationController class]]) return (UINavigationController *)r;
            if ([r isKindOfClass:[UIViewController class]]) {
                UIViewController *vc = (UIViewController *)r;
                if (vc.navigationController) return vc.navigationController;
            }
            r = r.nextResponder;
        }
    } @catch (id e) {}
    return nil;
}

// 顶层控制器是否应被排除（它们自带横向手势/全屏浏览，会和我们抢手势）
static BOOL FSBIsExcludedTopVC(UIViewController *vc) {
    if (!vc) return YES;
    static NSArray *excluded;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        excluded = @[
            // 系统通用冲突类（任意 App 都可能出现）
            @"UIImagePickerController",          // 相册/相机选择器
            @"AVPlayerViewController",           // 系统视频播放器
            @"UIDocumentInteractionController",  // 文件预览
            @"QLPreviewController",              // Quick Look 预览
            @"WKFullScreenWebViewController",    // WebView 全屏
            // 微信图片/视频查看器（注微信时用）
            @"WXFullScreenViewController",
            @"MMImagePreviewViewController",
            @"MMVideoPlayerViewController",
            @"PUPhotoBrowserViewController",
        ];
    });
    for (NSString *name in excluded) {
        Class c = NSClassFromString(name);
        if (c && [vc isKindOfClass:c]) return YES;
    }
    return NO;
}

// 转场进行中 / 上面盖着模态 / 正在被移除 → 不触发
static BOOL FSBNavBusy(UINavigationController *nav) {
    @try {
        if (!nav) return YES;
        if (nav.transitionCoordinator != nil) return YES;
        if (nav.presentedViewController != nil) return YES;
        if (nav.isBeingDismissed || nav.isBeingPresented) return YES;
        if (nav.isMovingFromParentViewController) return YES;
    } @catch (id e) {}
    return NO;
}

// ============================== 5. 手势代理 =================================
// 手势转发器：手势 target 用我们自己持有的对象。
// 只响应"松手"：直接调用公开 API popViewControllerAnimated:，
// 不转发任何系统私有转场方法（私有转场在 Flutter/混合栈里重入会卡死）。
@interface FSBGestureForwarder : NSObject
+ (instancetype)shared;
@end

@implementation FSBGestureForwarder
+ (instancetype)shared {
    static FSBGestureForwarder *s; static dispatch_once_t t;
    dispatch_once(&t, ^{ s = [FSBGestureForwarder new]; });
    return s;
}

- (void)fsbHandlePan:(UIPanGestureRecognizer *)pan {
    @try {
        if (pan.state != UIGestureRecognizerStateEnded) return;   // 只处理松手
        UINavigationController *nav = FSBNavForView(pan.view);
        if (!nav || nav.viewControllers.count < 2) return;
        if (FSBNavBusy(nav)) return;                               // 转场/模态中不触发
        [nav popViewControllerAnimated:YES];                       // 公开 API，系统级防重入
    } @catch (id e) {}
}
@end

@interface FSBGestureDelegate : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
@end

@implementation FSBGestureDelegate
+ (instancetype)shared {
    static FSBGestureDelegate *s; static dispatch_once_t t;
    dispatch_once(&t, ^{ s = [FSBGestureDelegate new]; });
    return s;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    @try {
        if (![g isKindOfClass:[UIPanGestureRecognizer class]]) return NO;
        UIPanGestureRecognizer *pan = (UIPanGestureRecognizer *)g;
        UINavigationController *nav = FSBNavForView(g.view);
        if (!nav || nav.viewControllers.count < 2) return NO;
        if (FSBNavBusy(nav)) return NO;

        CGPoint t = [pan translationInView:g.view];
        if (t.x <= 2.0) return NO;                    // 必须向右
        CGFloat ax = fabs(t.x), ay = fabs(t.y);
        if (ax <= ay) return NO;                      // 必须比纵向更横向
        if (ay / ax > 0.98) return NO;                // 太斜不算

        // 左边缘让位给系统原生边缘手势（它更早、更跟手）
        if ([pan locationInView:g.view].x <= kFSBLeftZone) return NO;
        return YES;
    } @catch (id e) { return NO; }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return NO;
}

// 落在「真能横向滚动的 UIScrollView」上时不抢手势
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)touch {
    @try {
        UIView *v = touch.view;
        UIView *root = g.view;
        while (v && v != root) {
            if ([v isKindOfClass:[UIScrollView class]]) {
                UIScrollView *sv = (UIScrollView *)v;
                if (sv.contentSize.width > sv.bounds.size.width + 8.0) return NO;
            }
            v = v.superview;
        }
    } @catch (id e) {}
    return YES;
}
@end

// ============================== 7. 安装 =====================================
static void FSBInstallOnNav(UINavigationController *nav);

static void FSBInstallOnNav(UINavigationController *nav) {
    @try {
        if (!nav || ![nav isKindOfClass:[UINavigationController class]]) return;
        UIView *host = nav.view;
        if (!host) return;
        if (nav.viewControllers.count < 2) return;

        // 幂等：已经装过直接返回
        for (UIGestureRecognizer *g in host.gestureRecognizers) {
            if ([g isMemberOfClass:[FSBFullScreenPan class]]) return;
        }
        // 顶层是媒体/图片查看器时不装（它们自己有横向手势）
        if (FSBIsExcludedTopVC(nav.topViewController)) return;

        // target 用我们自己的转发器：松手时走公开 API popViewControllerAnimated:，
        // 不转发任何系统私有转场方法（私有转场在 Flutter/混合栈里重入会卡死）
        FSBFullScreenPan *pan = [[FSBFullScreenPan alloc] initWithTarget:[FSBGestureForwarder shared]
                                                                  action:@selector(fsbHandlePan:)];
        pan.delegate = [FSBGestureDelegate shared];
        pan.maximumNumberOfTouches = 1;
        pan.cancelsTouchesInView = NO;
        pan.delaysTouchesBegan = NO;

        [pan addTarget:[FSBHaptics shared] action:@selector(trackGesture:)];
        [host addGestureRecognizer:pan];
        NSLog(@"[FullScreenBack] installed on %@ stack=%lu",
              NSStringFromClass([nav class]), (unsigned long)nav.viewControllers.count);
    } @catch (id e) {}
}

// 递归遍历：nav / tab / split / child / presented（带深度上限，防异常深层树拖死主线程）
static void FSBWalk(UIViewController *vc) {
    if (!vc) return;
    static int depth = 0;
    if (depth > 64) return;
    depth++;
    @try {
        if ([vc isKindOfClass:[UINavigationController class]]) {
            FSBInstallOnNav((UINavigationController *)vc);
            for (UIViewController *c in ((UINavigationController *)vc).viewControllers) FSBWalk(c);
        }
        if ([vc isKindOfClass:[UITabBarController class]]) {
            for (UIViewController *c in ((UITabBarController *)vc).viewControllers) FSBWalk(c);
        }
        if ([vc isKindOfClass:[UISplitViewController class]]) {
            for (UIViewController *c in ((UISplitViewController *)vc).viewControllers) FSBWalk(c);
        }
        for (UIViewController *c in vc.childViewControllers) FSBWalk(c);
        if (vc.presentedViewController) FSBWalk(vc.presentedViewController);
    } @catch (id e) {}
    depth--;
}

static void FSBInstallAll(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UIApplication *app = [UIApplication sharedApplication];
            // 最低 iOS 15：只走 Scene 多窗口路径，全部 window 都遍历（不只 key window）
            for (UIScene *scene in app.connectedScenes) {
                if (![scene isKindOfClass:[UIWindowScene class]]) continue;
                for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                    if (w.rootViewController) FSBWalk(w.rootViewController);
                }
            }
        } @catch (id e) {}
    });
}

// ============================== 9. Hook =====================================
// 只 swizzle 两个栈变化方法（push / setViewControllers）。
// 注意：不再 swizzle UIViewController.viewDidAppear: 和 nav 的 viewDidLoad/viewDidAppear:
// —— 这两个在 Flutter 类应用里会被引擎高频触发，主线程叠加手势安装会拖死界面（实测卡死）。
typedef struct { Class cls; SEL sel; IMP orig; } FSBSwizzle;

static FSBSwizzle gSwizzle[4];
static int gSwizzleCount = 0;

static void FSBSwizzleMethod(Class cls, SEL sel, IMP newImp) {
    @try {
        if (!cls || !sel || !newImp || gSwizzleCount >= 4) return;
        FSBSwizzle *slot = &gSwizzle[gSwizzleCount++];
        slot->cls = cls;
        slot->sel = sel;
        slot->orig = NULL;
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) {
            // 类本身没实现（纯继承），直接挂新实现，没有原实现可调
            class_addMethod(cls, sel, newImp, "@@:");
            return;
        }
        slot->orig = method_getImplementation(m);
        class_replaceMethod(cls, sel, newImp, method_getTypeEncoding(m));
    } @catch (id e) {}
}

// 槽位索引（必须与 FSBEntry 中的注册顺序一致）
#define SW_NAV_PUSH   0
#define SW_NAV_SETVCS 1

static void FSB_UINavigationController_pushViewController(id self, SEL _cmd, UIViewController *vc, BOOL animated) {
    @try {
        IMP o = gSwizzle[SW_NAV_PUSH].orig;
        if (o) ((void (*)(id, SEL, id, BOOL))o)(self, _cmd, vc, animated);
    } @catch (id e) {}
    // push 之后 stack 变化，下一轮 runloop 再装
    dispatch_async(dispatch_get_main_queue(), ^{ FSBInstallOnNav(self); });
}
static void FSB_UINavigationController_setViewControllers(id self, SEL _cmd, NSArray *vcs, BOOL animated) {
    @try {
        IMP o = gSwizzle[SW_NAV_SETVCS].orig;
        if (o) ((void (*)(id, SEL, id, BOOL))o)(self, _cmd, vcs, animated);
    } @catch (id e) {}
    dispatch_async(dispatch_get_main_queue(), ^{ FSBInstallOnNav(self); });
}

// ============================== 10. 入口 ====================================
__attribute__((constructor)) static void FSBEntry(void) {
    @autoreleasepool {
        @try {
            Class navCls = objc_getClass("UINavigationController");
            gSwizzleCount = 0;
            FSBSwizzleMethod(navCls, sel_registerName("pushViewController:animated:"),
                             (IMP)FSB_UINavigationController_pushViewController);
            FSBSwizzleMethod(navCls, sel_registerName("setViewControllers:animated:"),
                             (IMP)FSB_UINavigationController_setViewControllers);

            // 延迟全量安装（等启动完成后 controller 树就绪）
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ FSBInstallAll(); });

            // App 回前台 / 新 window 出现时重装（覆盖动态创建的 nav）
            NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
            for (NSString *name in @[UIApplicationDidBecomeActiveNotification,
                                     UIApplicationWillEnterForegroundNotification,
                                     UIWindowDidBecomeKeyNotification]) {
                [nc addObserverForName:name object:nil queue:[NSOperationQueue mainQueue]
                            usingBlock:^(NSNotification *n) { FSBInstallAll(); }];
            }
            NSLog(@"[FullScreenBack] loaded (universal)");
        } @catch (id e) {}
    }
}
