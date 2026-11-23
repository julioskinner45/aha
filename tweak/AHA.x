// AHA.x — Shopee app 内采集客户端 v0.5.6（导航 = Ajie 逐字复刻 + 面包屑诊断）
//
// v0.5.6 关键改动（对照 Ajie 0.1.3 反汇编逐条对齐）：
//   1. 导航管理器解析：BTAppManager/BTApplicationAddonProvider/SHPNavigator 三类候选
//      → 单例 getter（sharedInstance/sharedManager/defaultManager/manager/shared）
//      → 属性钻取（appManager/navigationManager/navigator/router/pageNavigator…），
//      验收标准 = 对象响应 navigateFromViewController:…/pushFromViewController:…
//   2. 参数传递：NSInvocation 签名驱动 + NSNull 转 NULL（Ajie 同款），不再裸 msgSend 猜参
//   3. route 字符串 4 种格式轮试（item_id/shop_id、good_id/shop_id、shopid/itemid、PRODUCT_PAGE）
//   4. 回根后再跳：pop 完等 0.4 秒（Ajie 0.35s 同款），不跟回根动画打架
//   5. 诊断：关键步骤写「面包屑」到 NSUserDefaults，闪退后下次启动面板直接报最后一步；
//      崩溃 handler 延迟 6 秒重装（覆盖 Shopee 自己装的 handler，否则永远拿不到日志）
//
// 采集方式（Ajie 同款，不再用 NSURLProtocol——后台会话挂自定义协议会直接崩）：
//   hook -[NSURLSession dataTaskWithRequest:completionHandler:] 与
//        -[NSURLSession dataTaskWithURL:completionHandler:]，
//   对 /api/v4/pdp/ 请求把 completionHandler 包一层：app 照常收发，我们留副本。
//   同时记住 app 自己发出的 pdp 请求头（Cookie/UA/af-ac-enc-dat 等全套上下文），
//   页面打不开时用这份上下文直接调 get_pc 兜底（Direct PDP）——裸调必被
//   SGW 风控墙（HTTP 403 / error 90309999）拦，必须重放 app 自己的头。
//
// 风控识别：HTTP 403 / 90309999 / get_pc error 266900002 → 面板红字提示。
//
// UI（Ajie 同款原生 UIKit，无 WebView 无 html）：
//   悬浮窗（passthrough UIWindow，面板外触摸穿透回 app）
//   header 可拖动 · ⚙设置（只有服务器地址） · — 收起成小球
//   状态条 · 大号 成单计数 · 任务行 · 账号框 · 间隔/休息三个框
//   一个大按钮 = 开始（自动登录）/ 停止，同一按钮切换 · 清零
//   UITextView 日志窗（等宽字体自动滚底） · 右下角拉拽改面板大小
//
// 登录：敞口模式 —— 手机面板只填账号名（/api/pool/login），无任何密码字段。
// 自签证书：中枢是自签 HTTPS，会话统一挂 AHATrustDelegate 接受 serverTrust。
//
// 全被动：不改任何请求/响应、不做检测绕过、不隐藏越狱。

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <signal.h>
#import <execinfo.h>
#import <fcntl.h>
#import <unistd.h>
#import <stdio.h>

static NSString *const kAhaCfgKey  = @"aha_cfg_v2";
static NSString *const kAhaCrashKey = @"aha_last_crash_v1";
static NSString *const kPdpMark   = @"/api/v4/pdp/";
static NSString *const kGetPcMark = @"/api/v4/pdp/get_pc";
// get_pc 直取模板（Ajie 同款：display_model_id=0 / model_selection_logic=3 / tz 480）
static NSString *const kGetPcTpl  = @"https://shopee.tw/api/v4/pdp/get_pc?display_model_id=0&item_id=%@&model_selection_logic=3&shop_id=%@&tz_offset_in_minutes=480&detail_level=0";

@class AHAPool;
@class AHACapture;
@class AHAPanel;
@class AHAUI;

static AHAPool *gPool = nil;
static AHAUI   *gUI   = nil;

static void ahaLog(NSString *lv, NSString *msg);          // 写日志 + 面板滚动
static void ahaRefreshUI(void);                           // 主线程刷面板

#pragma mark - 池客户端（接口声明）

@interface AHAPool : NSObject
@property(nonatomic, strong) NSMutableDictionary *cfg;
@property(nonatomic, strong) NSDate *lastRiskAlert;
@property(nonatomic, assign) BOOL running, connected, resting, risk;
@property(nonatomic, assign) NSInteger taken, ok;
@property(nonatomic, copy) NSString *me, *token, *taskLine;
@property(nonatomic, readonly) dispatch_queue_t q;
- (void)connect:(void (^)(void))after;
- (void)startLoop;
- (void)stopLoop;
- (void)helloTick;
- (void)riskHit;
- (void)saveCfg;
- (NSInteger)num:(NSString *)k def:(NSInteger)d;
- (NSString *)statusText;
- (NSString *)counterText;
- (NSString *)taskText;
- (NSArray *)logLines;
- (void)clearLog;
- (void)resetCounters;
@end

#pragma mark - 截包仓库（get_pc 回包副本 + app 请求上下文）

@interface AHACapture : NSObject
+ (AHACapture *)shared;
- (void)rememberContext:(NSURLRequest *)req;              // 记 pdp 请求全套头（Direct PDP 用）
- (void)inspectData:(NSData *)data response:(NSURLResponse *)resp
            request:(NSURLRequest *)req error:(NSError *)err;
- (NSString *)bodyForShop:(NSString *)shop item:(NSString *)item;
- (void)storeBody:(NSString *)body shop:(NSString *)shop item:(NSString *)item;
- (NSDictionary *)contextCopy;
@end

@implementation AHACapture {
  NSMutableDictionary *_bodies;   // @"shop|item" -> @{ body, at }
  NSMutableDictionary *_ctx;      // app 自己 pdp 请求头快照
}

+ (AHACapture *)shared {
  static AHACapture *s; static dispatch_once_t once;
  dispatch_once(&once, ^{ s = [[AHACapture alloc] init]; });
  return s;
}

- (instancetype)init {
  if ((self = [super init])) {
    _bodies = [NSMutableDictionary dictionary];
    _ctx    = [NSMutableDictionary dictionary];
  }
  return self;
}

- (void)rememberContext:(NSURLRequest *)req {
  NSDictionary *h = req.allHTTPHeaderFields;
  if (!h.count) return;
  @synchronized (self) {
    [_ctx removeAllObjects];
    [_ctx addEntriesFromDictionary:h];
  }
}

- (void)inspectData:(NSData *)data response:(NSURLResponse *)resp
            request:(NSURLRequest *)req error:(NSError *)err {
  if (err || !data.length) return;
  NSString *u = req.URL.absoluteString ?: @"";
  if ([u rangeOfString:kGetPcMark].location == NSNotFound) return;
  NSHTTPURLResponse *hr = [resp isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)resp : nil;
  NSInteger code = hr.statusCode;
  NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  if (!body.length) return;

  // —— 风控识别（Ajie 同款判据 + 弹窗提醒）——
  if (code == 403 || [body containsString:@"90309999"]) {
    ahaLog(@"e", @"⛔ 命中风控墙（HTTP 403 / 90309999）——建议暂停歇会");
    if (gPool) { dispatch_async(gPool.q, ^{ [gPool riskHit]; }); ahaRefreshUI(); }
    return;
  }
  if ([body containsString:@"266900002"]) {
    ahaLog(@"w", @"⚠️ get_pc 报 266900002（风控前置信号）");
    if (gPool) { dispatch_async(gPool.q, ^{ [gPool riskHit]; }); ahaRefreshUI(); }
    return;
  }
  if (code != 200) {
    ahaLog(@"w", [NSString stringWithFormat:@"get_pc HTTP %ld，未采", (long)code]);
    return;
  }
  if (gPool) { dispatch_async(gPool.q, ^{ gPool.risk = NO; }); }

  // —— 存副本（shop/item 从 query 取）——
  NSURLComponents *uc = [NSURLComponents componentsWithURL:req.URL resolvingAgainstBaseURL:NO];
  NSString *shop = nil, *item = nil;
  for (NSURLQueryItem *qi in uc.queryItems) {
    if ([qi.name isEqualToString:@"shop_id"]) shop = qi.value;
    if ([qi.name isEqualToString:@"item_id"]) item = qi.value;
  }
  if (shop.length && item.length) [self storeBody:body shop:shop item:item];
}

- (void)storeBody:(NSString *)body shop:(NSString *)shop item:(NSString *)item {
  @synchronized (self) {
    _bodies[[NSString stringWithFormat:@"%@|%@", shop, item]] =
        @{ @"body": body ?: @"", @"at": [NSDate date] };
    if (_bodies.count > 40) {           // 只留最近 40 个商品，防内存膨胀
      NSArray *keys = [_bodies keysSortedByValueUsingComparator:
          ^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [a[@"at"] compare:b[@"at"]];
          }];
      for (NSUInteger i = 0; i < keys.count - 40; i++) [_bodies removeObjectForKey:keys[i]];
    }
  }
}

- (NSString *)bodyForShop:(NSString *)shop item:(NSString *)item {
  __block NSString *out = nil;
  @synchronized (self) {
    NSDictionary *e = _bodies[[NSString stringWithFormat:@"%@|%@", shop, item]];
    out = e[@"body"];
  }
  return out;
}

- (NSDictionary *)contextCopy {
  @synchronized (self) { return [_ctx copy]; }
}
@end

#pragma mark - 自签证书信任（中枢是自签 HTTPS，默认会话直接拒 → 图1那种「证书无效」登录失败）

@interface AHATrustDelegate : NSObject <NSURLSessionDataDelegate> @end
@implementation AHATrustDelegate
- (void)URLSession:(NSURLSession *)session
    didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
    completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))h {
  if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust])
    h(NSURLSessionAuthChallengeUseCredential,
      [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust]);
  else
    h(NSURLSessionAuthChallengePerformDefaultHandling, nil);
}
@end

static NSURLSession *AhaSession(NSURLSessionConfiguration *cfg) {
  static AHATrustDelegate *td; static dispatch_once_t once;
  dispatch_once(&once, ^{ td = [[AHATrustDelegate alloc] init]; });
  return [NSURLSession sessionWithConfiguration:cfg delegate:td delegateQueue:nil];
}

#pragma mark - App 内路由导航（v0.5.6 = Ajie 反汇编逐字复刻，绝不跳出 app）

// —— 面包屑：每个关键步骤先把名字写进 NSUserDefaults，闪退后下次启动就能报「死在哪一步」——
static void ahaStep(NSString *tag) {
  @try {
    [[NSUserDefaults standardUserDefaults] setObject:tag forKey:@"aha_step_v1"];
    [[NSUserDefaults standardUserDefaults] synchronize];
  } @catch (__unused NSException *e) { /* 记录失败就算了 */ }
}

// 拿我们自己的悬浮窗（AHAUI 在后面才实现，属性走运行时取）
static UIWindow *ahaOwnWin(void) {
  if (!gUI) return nil;
  SEL s = NSSelectorFromString(@"win");
  if (![(id)gUI respondsToSelector:s]) return nil;
  return ((id(*)(id, SEL))objc_msgSend)((id)gUI, s);
}

// Shopee 自己的导航控制器（回根用）
static UINavigationController *ahaShopeeNav(void) {
  UIWindow *own = ahaOwnWin();
  for (UIWindow *w in [UIApplication sharedApplication].windows) {
    if (w == own) continue;
    UIViewController *vc = w.rootViewController;
    if (!vc) continue;
    if ([vc isKindOfClass:[UITabBarController class]])
      vc = [(UITabBarController *)vc selectedViewController];
    if ([vc isKindOfClass:[UINavigationController class]])
      return (UINavigationController *)vc;
  }
  return nil;
}

// —— NSInvocation 安全调用器（Ajie invokeSelector:onTarget:arguments: 逐字复刻）：
// 签名驱动、NSNull 转 NULL、标量按类型宽度取值、结构体一律拒绝。
// 不再裸 objc_msgSend 猜参数（v0.5.2/v0.5.4/v0.5.5 三连崩的主嫌）——
static BOOL ahaInvoke(id target, SEL sel, NSArray *args, NSString *tag) {
  if (!target || !sel) return NO;
  @try {
    NSMethodSignature *sig = [target methodSignatureForSelector:sel];
    if (!sig || sig.numberOfArguments < 2) return NO;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:target];
    [inv setSelector:sel];
    NSUInteger n = MIN(sig.numberOfArguments - 2, args.count);
    for (NSUInteger i = 0; i < n; i++) {
      const char *t = [sig getArgumentTypeAtIndex:i + 2];
      if (!t || !t[0]) return NO;
      id a = [args objectAtIndex:i];
      NSUInteger at = i + 2;
      switch (t[0]) {
        case '@': {
          id v = ([a isKindOfClass:[NSNull class]]) ? nil : a;    // NSNull → NULL（Ajie 同款）
          [inv setArgument:&v atIndex:at];
          break;
        }
        case 'q': case 'l': { long long v = [a respondsToSelector:@selector(longLongValue)] ? [a longLongValue] : 0; [inv setArgument:&v atIndex:at]; break; }
        case 'Q': case 'L': { unsigned long long v = [a respondsToSelector:@selector(unsignedLongLongValue)] ? [a unsignedLongLongValue] : 0; [inv setArgument:&v atIndex:at]; break; }
        case 'i': { int v = (int)[a respondsToSelector:@selector(intValue)] ? [a intValue] : 0; [inv setArgument:&v atIndex:at]; break; }
        case 'I': { unsigned int v = (unsigned int)[a respondsToSelector:@selector(unsignedIntValue)] ? [a unsignedIntValue] : 0; [inv setArgument:&v atIndex:at]; break; }
        case 's': { short v = (short)[a respondsToSelector:@selector(shortValue)] ? [a shortValue] : 0; [inv setArgument:&v atIndex:at]; break; }
        case 'S': { unsigned short v = (unsigned short)[a respondsToSelector:@selector(unsignedShortValue)] ? [a unsignedShortValue] : 0; [inv setArgument:&v atIndex:at]; break; }
        case 'c': { char v = (char)[a respondsToSelector:@selector(charValue)] ? [a charValue] : 0; [inv setArgument:&v atIndex:at]; break; }
        case 'C': { unsigned char v = (unsigned char)[a respondsToSelector:@selector(unsignedCharValue)] ? [a unsignedCharValue] : 0; [inv setArgument:&v atIndex:at]; break; }
        case 'B': case 'Z': { BOOL v = [a respondsToSelector:@selector(boolValue)] ? [a boolValue] : NO; [inv setArgument:&v atIndex:at]; break; }
        case 'd': { double v = [a respondsToSelector:@selector(doubleValue)] ? [a doubleValue] : 0; [inv setArgument:&v atIndex:at]; break; }
        case 'f': { float v = (float)[a respondsToSelector:@selector(floatValue)] ? [a floatValue] : 0; [inv setArgument:&v atIndex:at]; break; }
        default:
          ahaLog(@"w", [NSString stringWithFormat:@"内路由[%@]：第 %lu 个参数类型 '%c' 不支持，放弃", tag, (unsigned long)i + 1, t[0]]);
          return NO;   // 结构体/未知类型绝不硬调
      }
    }
    [inv invoke];
    return YES;
  } @catch (NSException *e) {
    ahaLog(@"w", [NSString stringWithFormat:@"内路由[%@]调用异常：%@", tag, e.reason]);
    return NO;
  }
}

// —— 管理器解析（Ajie resolvedNavigationManager 复刻）：
// 类候选 → 单例 getter → 属性钻取，验收 = 对象响应导航方法 ——
static BOOL ahaRespondsNav(id obj) {
  if (!obj) return NO;
  // v0.5.9：Ajie 实证的商品直开三连也算导航能力——BTAppManager 本尊往往只认这几个，
  // 之前只认 navigate/push 会把正牌 manager 拒之门外
  for (NSString *m in @[@"navigateFromViewController:destinationPath:navigateOption:completion:",
                        @"pushFromViewController:destinationPath:pushOption:completion:",
                        @"navigateToProduct:goodID:", @"openProductPage:goodID:", @"openProduct:goodID:"]) {
    if ([obj respondsToSelector:NSSelectorFromString(m)]) return YES;
  }
  return NO;
}

static id ahaMsgObj0(id obj, SEL s) {
  NSMethodSignature *sig = [obj methodSignatureForSelector:s];
  if (!sig || sig.numberOfArguments != 2) return nil;           // 只碰无参 getter
  if ([sig methodReturnType][0] != '@') return nil;             // 返回必须是对象
  return ((id(*)(id, SEL))objc_msgSend)(obj, s);
}

static id ahaResolveManager(void) {
  NSArray *clsNames = @[@"BTAppManager", @"BTApplicationAddonProvider", @"SHPNavigator"];
  NSArray *singles  = @[@"sharedInstance", @"sharedManager", @"defaultManager", @"manager", @"shared"];
  NSArray *drills   = @[@"appManager", @"navigationManager", @"navigator", @"defaultManager",
                        @"manager", @"navigatorManager", @"pageNavigator", @"router"];
  for (NSString *cn in clsNames) {
    Class c = NSClassFromString(cn);
    if (!c) continue;
    id base = nil;
    for (NSString *g in singles) {
      SEL s = NSSelectorFromString(g);
      if (![c respondsToSelector:s]) continue;
      id o = nil;
      @try { o = ((id(*)(id, SEL))objc_msgSend)(c, s); } @catch (__unused NSException *e) { continue; }
      if (o) { base = o; break; }
    }
    if (!base) continue;
    if (ahaRespondsNav(base)) return base;
    for (NSString *g in drills) {
      SEL s = NSSelectorFromString(g);
      if (![base respondsToSelector:s]) continue;
      id o = nil;
      @try { o = ahaMsgObj0(base, s); } @catch (__unused NSException *e) { continue; }
      if (ahaRespondsNav(o)) return o;
    }
  }
  return nil;
}

// —— 顶层 VC（Ajie topViewController 同思路）：主窗口 → root → 弹层/标签/导航栈逐层解 ——
static UIViewController *ahaResolvedTopVC(void) {
  UIWindow *own = ahaOwnWin();
  UIWindow *main = nil;
  for (UIWindow *w in [UIApplication sharedApplication].windows) {
    if (w == own || !w.rootViewController) continue;
    if (!main || w.isKeyWindow) main = w;
    if (w.isKeyWindow) break;
  }
  if (!main) return nil;
  UIViewController *vc = main.rootViewController;
  if (!vc) return nil;
  while (vc.presentedViewController) vc = vc.presentedViewController;
  if ([vc isKindOfClass:[UITabBarController class]])
    vc = [(UITabBarController *)vc selectedViewController] ?: vc;
  if ([vc isKindOfClass:[UINavigationController class]])
    vc = [(UINavigationController *)vc topViewController] ?: vc;
  while (vc.presentedViewController) vc = vc.presentedViewController;
  return vc;
}

// —— 路径对象（Ajie buildNavigationPathObjectForRoute: 复刻，v0.5.5 已对齐）——
static id ahaBuildPath(NSString *route) {
  Class pathCls = NSClassFromString(@"SHPNavigatorNavigationPath");
  if (!pathCls || route.length == 0) return nil;
  id (*msgObj)(id, SEL, id) = (id(*)(id, SEL, id))objc_msgSend;
  for (NSString *m in @[@"pathWithAppRL:", @"navigationPathWithAppRL:",
                        @"pathWithString:", @"navigationPathWithString:", @"pathWithRoute:"]) {
    SEL s = NSSelectorFromString(m);
    if ([pathCls respondsToSelector:s]) {
      @try {
        id p = msgObj(pathCls, s, route);
        if (p && [p isKindOfClass:pathCls]) return p;
      } @catch (__unused NSException *e) { /* 下一个候选 */ }
    }
  }
  // Ajie 同款兜底：alloc + initWithAppRL:/initWithString:/initWithRoute:（正规初始化器）
  @try {
    id p = [pathCls alloc];
    for (NSString *m in @[@"initWithAppRL:", @"initWithString:", @"initWithRoute:"]) {
      SEL s = NSSelectorFromString(m);
      if ([p respondsToSelector:s]) {
        id q = msgObj(p, s, route);
        if ([q isKindOfClass:pathCls]) return q;
      }
    }
  } @catch (__unused NSException *e) { /* 放弃 */ }
  return nil;
}

// —— 组装导航（Ajie navigateWithBTManagerToRoute: 复刻）：
// 4 种 route 格式轮试 × navigate/push 双候选 ——
static BOOL ahaNavInApp(NSString *shopId, NSString *itemId) {
  ahaStep(@"导航:解析管理器");
  id nav = ahaResolveManager();
  if (!nav) { ahaLog(@"i", @"内路由：没找到导航管理器（走网页兜底）"); return NO; }

  // route 4 连（Ajie 实证序）：item_id/shop_id → good_id/shop_id → shopid/itemid → PRODUCT_PAGE
  NSArray *routes = @[
    [NSString stringWithFormat:@"rn/PRODUCT_PAGE?item_id=%@&shop_id=%@", itemId, shopId],
    [NSString stringWithFormat:@"rn/PRODUCT_PAGE?good_id=%@&shop_id=%@", itemId, shopId],
    [NSString stringWithFormat:@"rn/PRODUCT_PAGE?shopid=%@&itemid=%@", shopId, itemId],
    [NSString stringWithFormat:@"PRODUCT_PAGE?itemid=%@&shopid=%@", itemId, shopId],
  ];
  SEL navSel  = NSSelectorFromString(@"navigateFromViewController:destinationPath:navigateOption:completion:");
  SEL pushSel = NSSelectorFromString(@"pushFromViewController:destinationPath:pushOption:completion:");

  for (NSString *route in routes) {
    ahaStep(@"导航:造路径对象");
    id path = nil;
    @try { path = ahaBuildPath(route); } @catch (__unused NSException *e) { path = nil; }
    if (!path) continue;
    UIViewController *vc = ahaResolvedTopVC();
    if (!vc) { ahaLog(@"w", @"内路由：拿不到顶层页面"); continue; }
    if ([nav respondsToSelector:navSel]) {
      ahaStep(@"导航:navigate 调用");
      if (ahaInvoke(nav, navSel, @[vc, path, [NSNull null], [NSNull null]], @"navigate")) return YES;
    }
    if ([nav respondsToSelector:pushSel]) {
      ahaStep(@"导航:push 调用");
      if (ahaInvoke(nav, pushSel, @[vc, path, [NSNull null], [NSNull null]], @"push")) return YES;
    }
  }

  // —— Ajie 兜底级（invokeRouteNavigationOnManager 实证）：manager 自带的商品直开方法，
  //    不需要路径对象，参数 [shopID, itemID]（nil→@""，Ajie 同款 csel）——
  //    虾皮 3.50.50 上路径工厂对不上时，这才是正牌出路
  NSString *shop = shopId ?: @"", *item = itemId ?: @"";
  for (NSString *m in @[@"navigateToProduct:goodID:", @"openProductPage:goodID:", @"openProduct:goodID:"]) {
    SEL s = NSSelectorFromString(m);
    if (![nav respondsToSelector:s]) continue;
    ahaStep(@"导航:商品直开");
    if (ahaInvoke(nav, s, @[shop, item], m)) {
      ahaLog(@"i", [NSString stringWithFormat:@"内路由：%@ 调用成功", m]);
      return YES;
    }
  }
  ahaLog(@"w", @"内路由全部候选失败（路径式+商品直开），任务将回池重试");
  return NO;
}

#pragma mark - 观察钩子（Ajie 同款：包 completionHandler，不碰 protocolClasses）

%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
    completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))handler {
  NSString *u = request.URL.absoluteString ?: @"";
  BOOL isPdp = ([u rangeOfString:kPdpMark].location != NSNotFound);
  if (isPdp) [[AHACapture shared] rememberContext:request];
  if (!isPdp || !handler) return %orig;
  NSURLRequest *reqCopy = [request copy];
  return %orig(request, ^(NSData *d, NSURLResponse *r, NSError *e) {
    [[AHACapture shared] inspectData:d response:r request:reqCopy error:e];
    handler(d, r, e);
  });
}
- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)URL
    completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))handler {
  NSString *u = URL.absoluteString ?: @"";
  BOOL isPdp = ([u rangeOfString:kPdpMark].location != NSNotFound);
  if (!isPdp || !handler) return %orig;
  NSURLRequest *req = [NSURLRequest requestWithURL:URL];
  [[AHACapture shared] rememberContext:req];
  return %orig(URL, ^(NSData *d, NSURLResponse *r, NSError *e) {
    [[AHACapture shared] inspectData:d response:r request:req error:e];
    handler(d, r, e);
  });
}
%end

#pragma mark - 池客户端（实现：登录 → 领单 → 浏览/截包 → 直传/代交）

@implementation AHAPool {
  dispatch_queue_t _q;
  NSMutableArray *_logs;          // 纯文本行
}

+ (AHAPool *)shared {
  static AHAPool *s; static dispatch_once_t once;
  dispatch_once(&once, ^{ s = [[AHAPool alloc] init]; });
  return s;
}

- (instancetype)init {
  if ((self = [super init])) {
    _q = dispatch_queue_create("aha.pool", DISPATCH_QUEUE_SERIAL);
    _logs = [NSMutableArray array];
    _cfg = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kAhaCfgKey].mutableCopy
               ?: [NSMutableDictionary dictionary];
    if (!_cfg[@"server"]) _cfg[@"server"] = @"https://140.235.98.220:29690";
    if (!_cfg[@"pid"]) _cfg[@"pid"] = [NSString stringWithFormat:@"phone-%@",
        [[NSUUID UUID].UUIDString substringToIndex:4].lowercaseString];
  }
  return self;
}

- (dispatch_queue_t)q { return _q; }

- (void)saveCfg { [[NSUserDefaults standardUserDefaults] setObject:self.cfg forKey:kAhaCfgKey]; }

- (NSString *)base {
  NSString *s = self.cfg[@"server"] ?: @"";
  while ([s hasSuffix:@"/"]) s = [s substringToIndex:s.length - 1];
  return s;
}

- (NSInteger)num:(NSString *)k def:(NSInteger)d {
  id v = self.cfg[k];
  NSInteger n = [v respondsToSelector:@selector(integerValue)] ? [v integerValue] : d;
  return n > 0 ? n : d;
}

- (NSString *)statusText {
  if (self.risk) return @"● 疑似风控（建议暂停）";
  if (!self.connected) return @"● 未连接";
  if (!self.running) return [NSString stringWithFormat:@"● 已连接 %@（待机）", self.me ?: @""];
  if (self.resting) return @"● 休息中";
  return [NSString stringWithFormat:@"● 运行中 · %@", self.me ?: @""];
}
- (NSString *)counterText {
  return [NSString stringWithFormat:@"成功 %ld", (long)self.ok];
}
- (NSString *)taskText { return self.taskLine ?: @""; }

- (NSArray *)logLines {
  @synchronized (_logs) { return [_logs copy]; }
}
- (void)clearLog { @synchronized (_logs) { [_logs removeAllObjects]; } }
- (void)resetCounters { self.taken = 0; self.ok = 0; self.taskLine = @""; }

- (void)appendLog:(NSString *)lv msg:(NSString *)msg {
  NSString *line;
  if ([lv isEqualToString:@"s"]) line = [NSString stringWithFormat:@"✔ %@", msg];
  else if ([lv isEqualToString:@"e"]) line = [NSString stringWithFormat:@"✖ %@", msg];
  else if ([lv isEqualToString:@"w"]) line = [NSString stringWithFormat:@"⚠ %@", msg];
  else line = msg;
  static NSDateFormatter *df; static dispatch_once_t dOnce;
  dispatch_once(&dOnce, ^{
    df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"HH:mm:ss";
  });
  line = [NSString stringWithFormat:@"%@ %@", [df stringFromDate:[NSDate date]], line];
  @synchronized (_logs) {
    [_logs addObject:line];
    if (_logs.count > 250) [_logs removeObjectsInRange:NSMakeRange(0, _logs.count - 250)];
  }
  ahaRefreshUI();
}

static void ahaLog(NSString *lv, NSString *msg) {
  if (gPool) [gPool appendLog:(lv ?: @"i") msg:(msg ?: @"")];
}

// —— 风控提醒（Ajie 同款弹窗）：状态沿触发 + 5 分钟节流，弹在我们自己的悬浮窗上 ——
static void ahaRiskAlertShow(void) {
  dispatch_async(dispatch_get_main_queue(), ^{
    UIWindow *w = ahaOwnWin();
    if (!w || !w.rootViewController) return;
    UIViewController *top = w.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"⚠️ 风控提醒"
        message:@"命中虾皮风控墙（HTTP 403 / 90309999 / get_pc 266900002）。\n建议点「■ 停止采集」歇几分钟再继续，频繁硬闯会加重。"
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
    [top presentViewController:a animated:YES completion:nil];
  });
}

- (void)riskHit {
  BOOL edge = !self.risk;                       // 未风控 → 风控 的跳变才弹
  NSDate *last = self.lastRiskAlert;
  BOOL throttled = (!edge && last && [last timeIntervalSinceNow] > -300);  // 持续风控期 5 分钟提醒一次
  self.risk = YES;
  if (edge || !throttled) {
    self.lastRiskAlert = [NSDate date];
    ahaRiskAlertShow();
  }
}

// —— HTTP（默认会话；pdp 请求顺带被钩子记住上下文，喂给 Direct PDP）——
- (void)api:(NSString *)path method:(NSString *)method body:(NSDictionary *)body
        done:(void (^)(NSDictionary *, NSError *))done {
  NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
      [NSURL URLWithString:[self.base stringByAppendingString:path]]];
  req.HTTPMethod = method ?: @"GET";
  req.timeoutInterval = 30;
  [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  if (self.token.length)
    [req setValue:[@"Bearer " stringByAppendingString:self.token] forHTTPHeaderField:@"Authorization"];
  if (body && ![req.HTTPMethod isEqualToString:@"GET"])
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
  static NSURLSession *sess = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    sess = AhaSession([NSURLSessionConfiguration defaultSessionConfiguration]);
  });
  [[sess dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
    id obj = (d && !e) ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    // done 可为 nil（心跳/上报都不关心回包）——v0.5.6 三次 SIGSEGV 实锤：
    // 崩点 api 完成块调 done 时 x21=0，far=0x10，正是 helloTick 传 done:nil 踩的
    if (done) done(([obj isKindOfClass:[NSDictionary class]] ? obj : @{}), e);
  }] resume];
}

// —— 登录（敞口：只发账号名，无密码；中枢 /api/pool/login 发池专用 token）——
- (void)connect:(void (^)(void))after {
  NSString *u = [self.cfg[@"user"] stringByTrimmingCharactersInSet:
      [NSCharacterSet whitespaceCharacterSet]];
  if (u.length == 0) { ahaLog(@"w", @"先填账号"); ahaRefreshUI(); return; }
  self.taskLine = @"";
  ahaLog(@"i", [NSString stringWithFormat:@"[%@] 正在登录 %@ …", u, self.base]);
  [self api:@"/api/pool/login" method:@"POST"
      body:@{ @"name": u }
      done:^(NSDictionary *j, NSError *e) {
    dispatch_async(self.q, ^{
      if (j && [j[@"ok"] boolValue]) {
        self.token = j[@"token"];
        self.me = u;
        self.connected = YES;
        ahaLog(@"s", [NSString stringWithFormat:@"已连接 %@（敞口模式 · 池隔离）", self.me]);
        if (after) after();
      } else {
        self.connected = NO; self.token = nil;
        ahaLog(@"e", [NSString stringWithFormat:@"登录失败：%@",
            j[@"error"] ?: (e.localizedDescription ?: @"网络不通")]);
      }
      ahaRefreshUI();
    });
  }];
}

// —— 心跳（10s，运行中才发）——
- (void)helloTick {
  if (!self.running || !self.token) return;
  [self api:@"/api/pool/hello" method:@"POST"
      body:@{ @"profileId": self.cfg[@"pid"] ?: @"" } done:nil];
}

// —— 开始 / 停止 ——
- (void)startLoop {
  if (!self.connected) { [self connect:^{ [self beginRun]; }]; return; }
  [self beginRun];
}
- (void)beginRun {
  dispatch_async(self.q, ^{
    if (self.running) return;
    self.running = YES; self.resting = NO; self.risk = NO;
    ahaLog(@"s", @"领单循环已开始");
    ahaRefreshUI();
    [self takeOnce];
  });
}
- (void)stopLoop {
  dispatch_async(self.q, ^{
    if (!self.running) return;
    self.running = NO;
    self.taskLine = @"";
    ahaLog(@"w", @"循环已停止");
    ahaRefreshUI();
  });
}

// —— 调度（间隔默认 0-0 秒：池子没单时听中枢 waitMs 节奏）——
- (double)randomGap {
  double lo = [self num:@"gapMin" def:0], hi = [self num:@"gapMax" def:0];
  if (hi < lo) hi = lo;
  return lo + arc4random_uniform((UInt32)(hi - lo + 1));
}
- (void)scheduleNext:(double)afterSec {
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(afterSec * NSEC_PER_SEC)),
      self.q, ^{
    if (!self.running) { ahaRefreshUI(); return; }
    [self takeOnce];
  });
}

- (void)takeOnce {
  dispatch_async(self.q, ^{
    if (!self.running || !self.token) { ahaRefreshUI(); return; }
    // 休息窗口（开关开着 + 每达 restEvery 单歇 restSec 秒）
    NSInteger every = [self num:@"restEvery" def:0];
    NSInteger rs = [self num:@"restSec" def:0];
    BOOL restOn = [self.cfg[@"restOn"] boolValue];
    if (restOn && every > 0 && rs > 0 && self.taken > 0 && (self.taken % every) == 0 && !self.resting) {
      self.resting = YES;
      ahaLog(@"w", [NSString stringWithFormat:@"已领 %ld 单，休息 %ld 分钟", (long)self.taken, (long)(rs / 60)]);
      ahaRefreshUI();
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(rs * NSEC_PER_SEC)),
          self.q, ^{ self.resting = NO; ahaLog(@"s", @"休息结束"); [self takeOnce]; });
      return;
    }
    self.taskLine = @"领取中…";
    ahaRefreshUI();
    [self api:@"/api/pool/take" method:@"POST"
        body:@{ @"profileId": self.cfg[@"pid"] ?: @"" }
        done:^(NSDictionary *j, NSError *e) {
      dispatch_async(self.q, ^{
        if (e) {
          ahaLog(@"e", [NSString stringWithFormat:@"领单请求失败：%@", e.localizedDescription]);
          self.taskLine = @"";
          ahaRefreshUI();
          [self scheduleNext:5];
          return;
        }
        NSDictionary *t = j[@"task"];
        if (![t isKindOfClass:[NSDictionary class]] || !t.count) {
          // 没单时的等待节奏：用户在面板设了间隔（非 0-0）→ 按自己设的来；
          // 默认 0-0 才听中枢 waitMs 派单节奏（v0.5.7 前一直被中枢 3s 盖住）
          NSInteger glo = [self num:@"gapMin" def:0], ghi = [self num:@"gapMax" def:0];
          double wait;
          if (glo > 0 || ghi > 0) {
            wait = [self randomGap];
          } else {
            wait = [j[@"waitMs"] isKindOfClass:[NSNumber class]]
                ? [j[@"waitMs"] doubleValue] / 1000.0 : 0;
          }
          self.taskLine = @"";
          ahaLog(@"i", [NSString stringWithFormat:@"池子暂无单，%.0f 秒后再领", wait]);
          ahaRefreshUI();
          [self scheduleNext:wait];
          return;
        }
        self.taken++;
        @try { [self handleTask:t]; } @catch (NSException *e) {
          ahaLog(@"e", [NSString stringWithFormat:@"任务处理异常已拦截：%@ — 任务回池", e.reason]);
          self.taskLine = @"";
          ahaRefreshUI();
          [self api:@"/api/pool/report" method:@"POST"
              body:@{ @"taskId": [NSString stringWithFormat:@"%@", t[@"id"] ?: @""],
                      @"profileId": self.cfg[@"pid"] ?: @"", @"status": @"skip" } done:nil];
          [self scheduleNext:5];
        }
      });
    }];
  });
}

// —— 任务处理：开商品页 → 等 app 自己的回包 → 没等到 Direct PDP 兜底 ——
- (void)handleTask:(NSDictionary *)t {
  NSString *taskId   = [NSString stringWithFormat:@"%@", t[@"id"] ?: @""];
  NSString *taskUrl  = [NSString stringWithFormat:@"%@", t[@"taskUrl"] ?: @""];
  NSString *shopId   = [NSString stringWithFormat:@"%@", t[@"shopId"] ?: @""];
  NSString *itemId   = [NSString stringWithFormat:@"%@", t[@"itemId"] ?: @""];
  NSString *acct     = [NSString stringWithFormat:@"%@", t[@"acct"] ?: @""];
  self.taskLine = [NSString stringWithFormat:@"#%@ [%@] item %@ · 打开商品页", taskId, acct, itemId];
  ahaStep(@"任务:领到单");
  ahaLog(@"s", [NSString stringWithFormat:@"领到单 #%@ [%@] item %@ shop %@", taskId, acct, itemId, shopId]);
  ahaRefreshUI();

  // App 内路由导航（Ajie 同款）：先收弹层回根 → 等 0.4 秒（Ajie 0.35s，不跟回根动画打架）→ 再跳；
  // 路由没打通才退回网页兜底并明确提示
  dispatch_async(dispatch_get_main_queue(), ^{
    UINavigationController *nc = ahaShopeeNav();
    if (nc) {
      if (nc.presentedViewController) [nc dismissViewControllerAnimated:NO completion:nil];
      if (nc.viewControllers.count > 2) {
        ahaStep(@"导航:回根");
        [nc popToRootViewControllerAnimated:NO];
        ahaLog(@"i", @"栈深超 2 层，先回首页再跳");
      }
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
      BOOL opened = NO;
      ahaStep(@"导航:开始");
      @try { opened = ahaNavInApp(shopId, itemId); } @catch (NSException *e) {
        ahaLog(@"e", [NSString stringWithFormat:@"导航异常已拦截：%@", e.reason]);
        opened = NO;
      }
      ahaStep(@"导航:结束");
      if (opened) {
        ahaLog(@"i", [NSString stringWithFormat:@"已打开商品页 #%@（app 内路由）", itemId]);
        return;
      }
      // v0.5.9：不再跳 Safari——Safari 是独立进程，get_pc 抓不到纯属白跑；
      // 直接等 Direct PDP 兜底（重放 app 请求头直调 get_pc），拿不到就回池
      ahaLog(@"w", @"App 内路由不可用，靠 Direct PDP 兜底直取数据");
    });
  });

  NSString *pid = self.cfg[@"pid"] ?: @"";
  NSString *jxServer = [NSString stringWithFormat:@"%@", t[@"jxServer"] ?: @""];
  NSString *subTok   = [NSString stringWithFormat:@"%@", t[@"submitToken"] ?: @""];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    // 等 app 自己的 get_pc 回包（最长 20 秒，0.5s 轮询；睡在后台队列，不堵 _q / 主线程）
    __block NSString *body = nil;
    for (int i = 0; i < 40 && !body; i++) {
      [NSThread sleepForTimeInterval:0.5];
      body = [[AHACapture shared] bodyForShop:shopId item:itemId];
      if (i == 19 && !body)
        ahaLog(@"i", [NSString stringWithFormat:@"#%@ 商品页开了但 10 秒还没等到回包，继续等…", taskId]);
    }
    NSString *via = @"app截包";
    if (!body) {
      ahaLog(@"i", [NSString stringWithFormat:@"#%@ 没等到 app 回包，Direct PDP 兜底直调…", taskId]);
      ahaStep(@"任务:DirectPDP兜底");
      body = [self directFetchShop:shopId item:itemId taskUrl:taskUrl];
      via = @"DirectPDP";
    }
    dispatch_async(self.q, ^{
      if (!body) {
        ahaLog(@"w", @"20 秒没等到商品回包（页面没开/没加载完），任务回池");
        self.taskLine = @"";
        ahaRefreshUI();
        [self api:@"/api/pool/report" method:@"POST"
            body:@{ @"taskId": taskId, @"profileId": pid, @"status": @"skip" } done:nil];
        [self scheduleNext:[self randomGap]];
        return;
      }
      self.taskLine = [NSString stringWithFormat:@"#%@ · 上传中（%@，%lu KB）",
          taskId, via, (unsigned long)[body lengthOfBytesUsingEncoding:NSUTF8StringEncoding] / 1024];
      ahaRefreshUI();
      ahaStep(@"任务:提交");
      [self submit:taskId taskUrl:taskUrl result:body jxServer:jxServer token:subTok];
    });
  });
}

// —— Direct PDP：重放 app 上下文调 get_pc（Ajie 的核心兜底）——
- (NSString *)directFetchShop:(NSString *)shopId item:(NSString *)itemId taskUrl:(NSString *)taskUrl {
  NSString *url = taskUrl;
  if ([url rangeOfString:kGetPcMark].location == NSNotFound)
    url = [NSString stringWithFormat:kGetPcTpl, itemId, shopId];
  NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
  req.HTTPMethod = @"GET";
  req.timeoutInterval = 20;
  NSDictionary *ctx = [[AHACapture shared] contextCopy];
  if (!ctx.count) return nil;
  for (NSString *k in ctx) {
    if ([k caseInsensitiveCompare:@"Content-Length"] == NSOrderedSame) continue;
    [req setValue:ctx[k] forHTTPHeaderField:k];
  }
  __block NSString *out = nil;
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  [[AhaSession([NSURLSessionConfiguration ephemeralSessionConfiguration])
   dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
    if (!e && d) {
      NSHTTPURLResponse *hr = [r isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)r : nil;
      if (hr.statusCode == 200)
        out = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
      else
        ahaLog(@"w", [NSString stringWithFormat:@"Direct PDP 回 HTTP %ld", (long)hr.statusCode]);
    } else if (e) {
      ahaLog(@"w", [NSString stringWithFormat:@"Direct PDP 网络错误：%@", e.localizedDescription]);
    }
    dispatch_semaphore_signal(sem);
  }] resume];
  dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(22 * NSEC_PER_SEC)));
  if (out.length > 100) [[AHACapture shared] storeBody:out shop:shopId item:itemId];
  else out = nil;
  return out;
}

// —— 提交：优先聚星直传（省跨境流量），失败回退中枢代交 ——
- (void)submit:(NSString *)taskId taskUrl:(NSString *)taskUrl result:(NSString *)result
      jxServer:(NSString *)jxServer token:(NSString *)token {
  if (jxServer.length > 8 && token.length > 8) {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:[jxServer stringByAppendingString:@"/api/task/submit/v2"]]];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 60;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:
        @{ @"appVersion": @"vv2", @"url": taskUrl, @"result": result } options:0 error:nil];
    static NSURLSession *sess = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      sess = AhaSession([NSURLSessionConfiguration defaultSessionConfiguration]);
    });
    [[sess dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
      dispatch_async(self.q, ^{
        BOOL ok = NO;
        NSString *codeTxt = @"无回包";
        if (!e && d) {
          id o = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
          id code = [o isKindOfClass:[NSDictionary class]] ? (o[@"code"] ?: [o valueForKeyPath:@"data.code"]) : nil;
          ok = [code isEqual:@200] || [code isEqual:@(200)];
          codeTxt = [NSString stringWithFormat:@"%@", code ?: @"格式异常"];
        }
        ahaLog(ok ? @"s" : @"i",
            [NSString stringWithFormat:@"#%@ 聚星直传%@", taskId,
              ok ? @"成功" : [NSString stringWithFormat:@"失败(code=%@)，转中枢代交", codeTxt]]);
        if (ok) [self markOk:taskId via:@"聚星直传"];
        else [self hubSubmit:taskId taskUrl:taskUrl result:result];
      });
    }] resume];
  } else {
    ahaLog(@"i", [NSString stringWithFormat:@"#%@ 任务无聚星直传参数，走中枢代交", taskId]);
    [self hubSubmit:taskId taskUrl:taskUrl result:result];
  }
}

- (void)hubSubmit:(NSString *)taskId taskUrl:(NSString *)taskUrl result:(NSString *)result {
  [self api:@"/api/pool/submit" method:@"POST"
      body:@{ @"taskId": taskId, @"url": taskUrl, @"result": result,
              @"profileId": self.cfg[@"pid"] ?: @"" }
      done:^(NSDictionary *j, NSError *e) {
    dispatch_async(self.q, ^{
      if (j && [j[@"ok"] boolValue]) [self markOk:taskId via:@"中枢代交"];
      else {
        ahaLog(@"e", [NSString stringWithFormat:@"上传失败：%@（任务回池）",
            j[@"error"] ?: (e.localizedDescription ?: @"未知")]);
        self.taskLine = @"";
        ahaRefreshUI();
        [self api:@"/api/pool/report" method:@"POST"
            body:@{ @"taskId": taskId, @"profileId": self.cfg[@"pid"] ?: @"", @"status": @"skip" }
            done:nil];
        [self scheduleNext:[self randomGap]];
      }
    });
  }];
}

- (void)markOk:(NSString *)taskId via:(NSString *)via {
  self.ok++;
  self.taskLine = @"";
  ahaLog(@"s", [NSString stringWithFormat:@"单子 %@ 已交（%@），累计成功 %ld", taskId, via, (long)self.ok]);
  ahaRefreshUI();
  // 聚星直传成功必须回执中枢记账（status=ok → 任务置 done + submitted+1）；
  // 中枢代交路径由 /api/pool/submit 自己记账，互斥不重复计
  if ([via isEqualToString:@"聚星直传"])
    [self api:@"/api/pool/report" method:@"POST"
        body:@{ @"taskId": taskId, @"profileId": self.cfg[@"pid"] ?: @"", @"status": @"ok" } done:nil];
  [self scheduleNext:[self randomGap]];
}

@end

#pragma mark - 悬浮面板（Ajie 同款原生 UI）

static UIColor *AhaColor(NSInteger r, NSInteger g, NSInteger b, CGFloat a) {
  return [UIColor colorWithRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:a];
}

// 按钮点击转 block（关联对象保活）
@interface AHAActionWrap : NSObject
@property(nonatomic, copy) void (^blk)(void);
@end
@implementation AHAActionWrap
- (void)fire { if (self.blk) self.blk(); }
@end
static void ahaTap(UIControl *c, void (^blk)(void)) {
  AHAActionWrap *w = [[AHAActionWrap alloc] init];
  w.blk = blk;
  objc_setAssociatedObject(c, (__bridge const void *)w, w, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  [c addTarget:w action:@selector(fire) forControlEvents:UIControlEventTouchUpInside];
}

// 面板外触摸穿透回 app（Ajie 的 passthrough 思路）
@interface AHAPassthroughWindow : UIWindow @end
@implementation AHAPassthroughWindow
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)event {
  UIView *v = [super hitTest:p withEvent:event];
  return (v == self || (self.rootViewController && v == self.rootViewController.view)) ? nil : v;
}
@end

// 面板容器：header 拖动 + 右下角 resize（实现放在 AHAUI 接口之后）
@interface AHAPanel : UIView @end

@interface AHAUI : NSObject
@property(nonatomic, strong) AHAPassthroughWindow *win;
@property(nonatomic, strong) AHAPanel *panel;
@property(nonatomic, strong) UIView *header, *mini;
@property(nonatomic, strong) UILabel *ttl, *statusLabel, *taskLabel, *counterLabel, *miniInfo, *rh;
@property(nonatomic, strong) UITextField *userField, *gapField, *restEveryField, *restSecField;
@property(nonatomic, strong) UIView *restRow;
@property(nonatomic, strong) UISwitch *restOnSwitch;
@property(nonatomic, strong) UILabel *restOnLabel;
@property(nonatomic, strong) UITextView *logView;
@property(nonatomic, strong) UIButton *gearBtn, *miniBtn, *startBtn, *resetBtn, *restBtn;
- (void)boot;
- (void)layoutPanel;
- (void)toggleRest;
- (void)restSwitchChanged;
- (void)updateRestTitle;
@end

@implementation AHAUI

+ (AHAUI *)shared {
  static AHAUI *s; static dispatch_once_t once;
  dispatch_once(&once, ^{ s = [[AHAUI alloc] init]; });
  return s;
}

static UITextField *AhaField(NSString *ph, NSString *icon) {
  UITextField *f = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 0, 34)];
  f.borderStyle = UITextBorderStyleRoundedRect;
  f.backgroundColor = AhaColor(255, 255, 255, 0.08);
  f.textColor = [UIColor whiteColor];
  f.font = [UIFont systemFontOfSize:13];
  f.attributedPlaceholder = [[NSAttributedString alloc]
      initWithString:ph attributes:@{ NSForegroundColorAttributeName: AhaColor(255,255,255,0.35) }];
  UILabel *lv = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 26, 30)];
  lv.text = icon;
  lv.textAlignment = NSTextAlignmentCenter;
  f.leftView = lv;
  f.leftViewMode = UITextFieldViewModeAlways;
  f.autocorrectionType = UITextAutocorrectionTypeNo;
  f.autocapitalizationType = UITextAutocapitalizationTypeNone;

  // 键盘上方「完成」工具条：数字键盘/无收起键的键盘也能一键收回
  CGFloat bw = [UIScreen mainScreen].bounds.size.width;
  UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, bw, 44)];
  bar.backgroundColor = AhaColor(28, 34, 48, 1);
  UIButton *done = [UIButton buttonWithType:UIButtonTypeCustom];
  done.frame = CGRectMake(bw - 80, 5, 72, 34);
  [done setTitle:@"完成 ▾" forState:UIControlStateNormal];
  done.titleLabel.font = [UIFont boldSystemFontOfSize:15];
  [done setTitleColor:AhaColor(120, 200, 255, 1) forState:UIControlStateNormal];
  ahaTap(done, ^{
    [[UIApplication sharedApplication] sendAction:@selector(resignFirstResponder)
        to:nil from:nil forEvent:nil];
  });
  [bar addSubview:done];
  UIView *ln = [[UIView alloc] initWithFrame:CGRectMake(0, 0, bw, 0.5)];
  ln.backgroundColor = AhaColor(255, 255, 255, 0.15);
  [bar addSubview:ln];
  f.inputAccessoryView = bar;
  return f;
}

static UIButton *AhaBtn(NSString *title, UIColor *bg, CGFloat size) {
  UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
  [b setTitle:title forState:UIControlStateNormal];
  b.backgroundColor = bg;
  b.titleLabel.font = [UIFont boldSystemFontOfSize:size];
  b.layer.cornerRadius = 7;
  b.clipsToBounds = YES;
  return b;
}

- (void)boot {
  if (self.win) return;
  CGRect scr = [UIScreen mainScreen].bounds;

  self.win = [[AHAPassthroughWindow alloc] initWithFrame:scr];
  self.win.windowLevel = UIWindowLevelAlert + 100;
  self.win.rootViewController = [UIViewController new];
  [self.win makeKeyAndVisible];

  CGFloat w = [gPool.cfg[@"panelW"] doubleValue] ?: 300;
  CGFloat h = [gPool.cfg[@"panelH"] doubleValue] ?: 380;
  if (w < 280 || w > scr.size.width) w = 300;
  if (h < 330 || h > scr.size.height) h = 380;
  CGFloat x = [gPool.cfg[@"panelX"] doubleValue] ?: 14;
  CGFloat y = [gPool.cfg[@"panelY"] doubleValue] ?: scr.size.height * 0.10;
  if (x < 0 || x + w > scr.size.width) x = 14;
  if (y < 0 || y + h > scr.size.height) y = scr.size.height * 0.10;

  AHAPanel *p = [[AHAPanel alloc] initWithFrame:CGRectMake(x, y, w, h)];
  p.backgroundColor = AhaColor(16, 18, 24, 0.97);
  p.layer.cornerRadius = 14;
  p.clipsToBounds = YES;
  p.layer.borderWidth = 1;
  p.layer.borderColor = AhaColor(255, 255, 255, 0.12).CGColor;
  self.panel = p;

  // header（拖动区 + 设置 + 收起）
  UIView *hd = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 40)];
  hd.backgroundColor = AhaColor(28, 34, 48, 1);
  self.header = hd;
  [p addSubview:hd];
  self.ttl = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, w - 90, 40)];
  self.ttl.text = @"⠿ AHA 采集";
  self.ttl.textColor = [UIColor whiteColor];
  self.ttl.font = [UIFont boldSystemFontOfSize:15];
  [hd addSubview:self.ttl];
  self.gearBtn  = AhaBtn(@"⚙", [UIColor clearColor], 16);
  self.miniBtn  = AhaBtn(@"—", [UIColor clearColor], 16);
  [hd addSubview:self.gearBtn];
  [hd addSubview:self.miniBtn];
  [hd addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:p action:@selector(ahaPan:)]];

  // 状态 / 大号计数 / 任务行（成单字要大）
  self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 48, w - 24, 20)];
  self.statusLabel.font = [UIFont boldSystemFontOfSize:14];
  self.counterLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 70, w - 24, 30)];
  self.counterLabel.font = [UIFont boldSystemFontOfSize:24];
  self.counterLabel.textColor = AhaColor(120, 200, 255, 1);
  self.taskLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 102, w - 24, 16)];
  self.taskLabel.font = [UIFont systemFontOfSize:11];
  self.taskLabel.textColor = AhaColor(255, 255, 255, 0.55);
  [p addSubview:self.statusLabel];
  [p addSubview:self.counterLabel];
  [p addSubview:self.taskLabel];

  // 账号（敞口：无密码）+ 间隔；休息默认折叠成一个按钮，点开展开
  self.userField = AhaField(@"账号（中枢后台账号）", @"👤");
  self.gapField = AhaField(@"间隔秒 0-0", @"⏱");
  self.gapField.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
  [p addSubview:self.userField];
  [p addSubview:self.gapField];
  self.restBtn = AhaBtn(@"☕ 休息：未开启", AhaColor(60, 66, 80, 1), 13);
  [p addSubview:self.restBtn];
  self.restRow = [[UIView alloc] initWithFrame:CGRectZero];
  // 休息总开关（第一行）+ 参数（第二行）
  self.restOnSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(0, 0, 51, 31)];
  self.restOnSwitch.onTintColor = AhaColor(34, 170, 90, 1);
  self.restOnSwitch.on = [gPool.cfg[@"restOn"] boolValue];
  [self.restOnSwitch addTarget:self action:@selector(restSwitchChanged)
      forControlEvents:UIControlEventValueChanged];
  self.restOnLabel = [[UILabel alloc] initWithFrame:CGRectMake(60, 4, 160, 24)];
  self.restOnLabel.font = [UIFont systemFontOfSize:13];
  self.restOnLabel.textColor = AhaColor(255, 255, 255, 0.8);
  [self.restRow addSubview:self.restOnSwitch];
  [self.restRow addSubview:self.restOnLabel];
  self.restEveryField = AhaField(@"做N单（0=不歇）", @"☕");
  self.restSecField   = AhaField(@"休分钟", @"⏸");
  self.restEveryField.keyboardType = UIKeyboardTypeNumberPad;
  self.restSecField.keyboardType = UIKeyboardTypeNumberPad;
  [self.restRow addSubview:self.restEveryField];
  [self.restRow addSubview:self.restSecField];
  self.restRow.hidden = YES;
  [p addSubview:self.restRow];

  // 一个大按钮 = 开始（自动登录）/ 停止，同一按钮；旁边小清零
  self.startBtn = AhaBtn(@"▶ 开始采集", AhaColor(34, 170, 90, 1), 18);
  self.startBtn.layer.cornerRadius = 10;
  self.resetBtn = AhaBtn(@"清零", AhaColor(90, 96, 108, 1), 14);
  self.resetBtn.layer.cornerRadius = 10;
  [p addSubview:self.startBtn];
  [p addSubview:self.resetBtn];

  // 日志窗
  self.logView = [[UITextView alloc] initWithFrame:CGRectZero];
  self.logView.editable = NO;
  self.logView.selectable = NO;
  self.logView.backgroundColor = AhaColor(0, 0, 0, 0.35);
  self.logView.textColor = AhaColor(235, 235, 235, 0.92);
  self.logView.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
  self.logView.layer.cornerRadius = 8;
  self.logView.clipsToBounds = YES;
  [p addSubview:self.logView];

  // 右下角 resize 手柄
  self.rh = [[UILabel alloc] initWithFrame:CGRectMake(w - 20, h - 20, 20, 20)];
  self.rh.text = @"◢";
  self.rh.textColor = AhaColor(255, 255, 255, 0.35);
  self.rh.textAlignment = NSTextAlignmentCenter;
  self.rh.userInteractionEnabled = YES;
  [p addSubview:self.rh];
  [self.rh addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:p action:@selector(ahaResize:)]];

  // 收起小球
  UIView *mv = [[UIView alloc] initWithFrame:CGRectMake(scr.size.width - 78, scr.size.height * 0.16, 64, 30)];
  mv.backgroundColor = AhaColor(28, 120, 240, 0.95);
  mv.layer.cornerRadius = 15;
  mv.hidden = YES;
  self.mini = mv;
  self.miniInfo = [[UILabel alloc] initWithFrame:mv.bounds];
  self.miniInfo.textAlignment = NSTextAlignmentCenter;
  self.miniInfo.font = [UIFont boldSystemFontOfSize:12];
  self.miniInfo.textColor = [UIColor whiteColor];
  [mv addSubview:self.miniInfo];
  UITapGestureRecognizer *mvTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(miniTapped)];
  [mv addGestureRecognizer:mvTap];
  UIPanGestureRecognizer *mvPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(miniPan:)];
  [mv addGestureRecognizer:mvPan];
  UIView *root = self.win.rootViewController.view;
  [root addSubview:mv];
  [root addSubview:p];

  // 交互
  ahaTap(self.gearBtn,  ^{ [[AHAUI shared] showSettings]; });
  ahaTap(self.restBtn,  ^{ [[AHAUI shared] toggleRest]; });
  ahaTap(self.miniBtn,  ^{ [[AHAUI shared] collapse:YES]; });
  ahaTap(self.startBtn, ^{
    [self.panel endEditing:YES];
    if (gPool.running) [gPool stopLoop];
    else [gPool startLoop];          // 未登录会自动先登录再开始
  });
  ahaTap(self.resetBtn, ^{ [self.panel endEditing:YES]; [gPool resetCounters]; ahaLog(@"i", @"计数已清零"); });

  // 输入框预填（间隔默认 0-0；休息按分钟显示，内部存秒）+ 失焦保存
  self.userField.text = gPool.cfg[@"user"] ?: @"";
  NSInteger lo = [gPool num:@"gapMin" def:0], hi = [gPool num:@"gapMax" def:0];
  self.gapField.text = [NSString stringWithFormat:@"%ld-%ld", (long)lo, (long)hi];
  self.restEveryField.text = [NSString stringWithFormat:@"%ld", (long)[gPool num:@"restEvery" def:0]];
  NSInteger mins0 = ([gPool num:@"restSec" def:0]) / 60;
  self.restSecField.text = [NSString stringWithFormat:@"%ld", (long)mins0];
  self.restOnSwitch.on = [gPool.cfg[@"restOn"] boolValue];
  if (self.restOnSwitch.on) self.restRow.hidden = NO;
  [self updateRestTitle];
  for (UITextField *f in @[self.userField, self.gapField, self.restEveryField, self.restSecField])
    [f addTarget:self action:@selector(fieldsChanged) forControlEvents:UIControlEventEditingDidEnd];

  [self layoutPanel];
  [self refresh];

  // 心跳 10s
  __weak AHAPool *wp = gPool;
  [NSTimer scheduledTimerWithTimeInterval:10 repeats:YES block:^(__unused NSTimer *t) {
    [wp helloTick];
  }];

  ahaLog(@"s", @"AHA 已注入（被动观察模式，不改任何请求）");
}

- (void)fieldsChanged {
  [self.panel endEditing:YES];      // 保存完把键盘收回去
  gPool.cfg[@"user"] = self.userField.text ?: @"";
  NSString *s = [self.gapField.text stringByReplacingOccurrencesOfString:@" " withString:@""];
  NSArray *parts = [s componentsSeparatedByString:@"-"];
  NSInteger lo = MAX([parts.firstObject integerValue], 0);
  NSInteger hi = parts.count > 1 ? MAX([parts[1] integerValue], 0) : lo;
  if (hi < lo) hi = lo;
  gPool.cfg[@"gapMin"] = @(lo);
  gPool.cfg[@"gapMax"] = @(hi);
  gPool.cfg[@"restEvery"] = @(MAX([self.restEveryField.text integerValue], 0));
  NSInteger mins = MAX([self.restSecField.text integerValue], 0);
  gPool.cfg[@"restSec"] = @(mins * 60);      // 面板按分钟，内部按秒
  [gPool saveCfg];
  [self updateRestTitle];
  ahaLog(@"i", @"配置已保存（本机）");
}

// 休息折叠按钮：点开/收起「开关 + 做N单休M分钟」
- (void)toggleRest {
  self.restRow.hidden = !self.restRow.hidden;
  [self updateRestTitle];
  [self layoutPanel];
}
- (void)restSwitchChanged {
  gPool.cfg[@"restOn"] = @(self.restOnSwitch.on);
  [gPool saveCfg];
  [self updateRestTitle];
  ahaLog(@"i", self.restOnSwitch.on ? @"休息已开启" : @"休息已关闭");
}
- (void)updateRestTitle {
  NSInteger every = MAX([self.restEveryField.text integerValue], 0);
  NSInteger mins  = MAX([self.restSecField.text integerValue], 0);
  BOOL on = self.restOnSwitch.on;
  NSString *t = (!on || every <= 0)
      ? @"☕ 休息：未开启"
      : [NSString stringWithFormat:@"☕ 休息：每 %ld 单休 %ld 分钟", (long)every, (long)mins];
  [self.restBtn setTitle:t forState:UIControlStateNormal];
  self.restBtn.backgroundColor = on && every > 0
      ? AhaColor(34, 120, 80, 1) : AhaColor(60, 66, 80, 1);
  self.restOnLabel.text = @"启用休息（按上面的单数和分钟歇）";
}

- (void)showSettings {
  UIAlertController *a = [UIAlertController alertControllerWithTitle:@"服务器地址"
      message:nil preferredStyle:UIAlertControllerStyleAlert];
  [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
    f.placeholder = @"https://140.235.98.220:29690";
    f.text = gPool.cfg[@"server"] ?: @"";
  }];
  [a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *act) {
    NSString *sv = a.textFields[0].text ?: @"";
    if (sv.length) {
      gPool.cfg[@"server"] = sv;
      [gPool saveCfg];
      ahaLog(@"i", @"服务器已保存");
    }
  }]];
  [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
  UIViewController *top = self.win.rootViewController;
  while (top.presentedViewController) top = top.presentedViewController;
  [top presentViewController:a animated:YES completion:nil];
}

- (void)collapse:(BOOL)mini {
  self.panel.hidden = mini;
  self.mini.hidden = !mini;
  if (mini) {
    CGRect scr = [UIScreen mainScreen].bounds;
    self.mini.frame = CGRectMake(scr.size.width - 78, MIN(MAX(self.panel.frame.origin.y + 20, 60), scr.size.height - 60), 64, 30);
    self.miniInfo.text = [NSString stringWithFormat:@"成 %ld", (long)gPool.ok];
  }
}
- (void)miniTapped { [self collapse:NO]; }
- (void)miniPan:(UIPanGestureRecognizer *)g {
  static CGPoint origin;
  if (g.state == UIGestureRecognizerStateBegan) origin = self.mini.center;
  if (g.state == UIGestureRecognizerStateChanged) {
    CGPoint t = [g translationInView:self.mini];
    self.mini.center = CGPointMake(origin.x + t.x, origin.y + t.y);
  }
}

- (void)layoutPanel {
  CGRect f = self.panel.bounds;
  CGFloat w = f.size.width, h = f.size.height;
  self.header.frame = CGRectMake(0, 0, w, 40);
  self.ttl.frame = CGRectMake(12, 0, w - 90, 40);
  self.gearBtn.frame = CGRectMake(w - 72, 4, 32, 32);
  self.miniBtn.frame = CGRectMake(w - 40, 4, 36, 32);
  self.statusLabel.frame  = CGRectMake(12, 48, w - 24, 20);
  self.counterLabel.frame = CGRectMake(12, 70, w - 24, 30);
  self.taskLabel.frame    = CGRectMake(12, 102, w - 24, 16);
  self.userField.frame = CGRectMake(12, 122, w - 24, 34);
  CGFloat fw = (w - 12 * 2 - 8) / 2;
  self.gapField.frame = CGRectMake(12, 162, fw, 32);
  self.restBtn.frame  = CGRectMake(12 + fw + 8, 162, fw, 32);
  CGFloat y = 200;
  if (!self.restRow.hidden) {                 // 休息展开：开关行 + 参数行 + 下推内容
    self.restRow.frame = CGRectMake(12, y, w - 24, 76);
    self.restOnSwitch.frame = CGRectMake(0, 2, 51, 31);
    self.restOnLabel.frame  = CGRectMake(60, 8, w - 24 - 60, 24);
    CGFloat rw = (w - 24 - 8) / 2;
    self.restEveryField.frame = CGRectMake(0, 40, rw, 32);
    self.restSecField.frame   = CGRectMake(rw + 8, 40, rw, 32);
    y += 84;
  }
  self.startBtn.frame = CGRectMake(12, y, w - 12 * 2 - 52 - 8, 46);
  self.resetBtn.frame = CGRectMake(w - 12 - 52, y, 52, 46);
  y += 54;
  self.logView.frame  = CGRectMake(12, y, w - 24, h - y - 14);
  self.rh.frame       = CGRectMake(w - 20, h - 20, 20, 20);
}

- (void)refresh {
  if (!self.panel) return;
  self.statusLabel.text = gPool.statusText;
  self.statusLabel.textColor = gPool.risk ? AhaColor(255, 90, 80, 1)
      : (gPool.running ? AhaColor(80, 220, 120, 1)
      : (gPool.connected ? AhaColor(120, 200, 255, 1) : AhaColor(255, 255, 255, 0.4)));
  self.counterLabel.text = gPool.counterText;
  self.taskLabel.text = gPool.taskText;
  // 大按钮 = 开始/停止 同一按钮
  if (gPool.running) {
    [self.startBtn setTitle:@"■ 停止采集" forState:UIControlStateNormal];
    self.startBtn.backgroundColor = AhaColor(200, 60, 56, 1);
  } else {
    [self.startBtn setTitle:@"▶ 开始采集" forState:UIControlStateNormal];
    self.startBtn.backgroundColor = AhaColor(34, 170, 90, 1);
  }
  self.miniInfo.text = [NSString stringWithFormat:@"成 %ld", (long)gPool.ok];
  NSArray *lines = gPool.logLines;
  if (lines.count) {
    self.logView.text = [lines componentsJoinedByString:@"\n"];
    [self.logView scrollRangeToVisible:NSMakeRange(self.logView.text.length, 0)];
  }
}

@end

static void ahaRefreshUI(void) {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (gUI) [gUI refresh];
  });
}

#pragma mark - 面板容器实现（要在 AHAUI 接口之后才能调 layoutPanel）

@implementation AHAPanel
- (void)ahaPan:(UIPanGestureRecognizer *)g {
  static CGPoint origin;
  if (g.state == UIGestureRecognizerStateBegan) origin = self.center;
  if (g.state == UIGestureRecognizerStateChanged) {
    CGPoint t = [g translationInView:self];
    self.center = CGPointMake(origin.x + t.x, origin.y + t.y);
  }
  if (g.state == UIGestureRecognizerStateEnded && gPool) {
    gPool.cfg[@"panelX"] = @(self.frame.origin.x);
    gPool.cfg[@"panelY"] = @(self.frame.origin.y);
    [gPool saveCfg];
  }
}
- (void)ahaResize:(UIPanGestureRecognizer *)g {
  static CGFloat w0, h0;
  if (g.state == UIGestureRecognizerStateBegan) { w0 = self.frame.size.width; h0 = self.frame.size.height; }
  if (g.state == UIGestureRecognizerStateChanged) {
    CGPoint t = [g translationInView:self];
    CGFloat scrW = [UIScreen mainScreen].bounds.size.width;
    CGFloat scrH = [UIScreen mainScreen].bounds.size.height;
    CGFloat w = MIN(MAX(w0 + t.x, 280), scrW - 20);
    CGFloat h = MIN(MAX(h0 + t.y, 330), scrH - 40);
    self.frame = CGRectMake(self.frame.origin.x, self.frame.origin.y, w, h);
    if (gUI) [gUI layoutPanel];
  }
  if (g.state == UIGestureRecognizerStateEnded && gPool) {
    gPool.cfg[@"panelW"] = @(self.frame.size.width);
    gPool.cfg[@"panelH"] = @(self.frame.size.height);
    [gPool saveCfg];
  }
}
@end

#pragma mark - 入口（显式自定义构造函数必须手动初始化钩子组 —— v0.2.0 的血坑）

// —— 崩溃记录器：闪退时把根因写进 NSUserDefaults，下次启动面板日志直接显示 ——
// 目的：不再猜闪退原因。NSException（如 unrecognized selector / 参数非法）走
// NSSetUncaughtExceptionHandler 能拿到完整 reason + 调用栈；段错误类（SIGSEGV/
// SIGABRT/SIGBUS/SIGILL/SIGTRAP）走 signal 处理器记信号类型。
static void ahaCrashRecord(NSString *tag, NSString *detail) {
  @try {
    static NSDateFormatter *df; static dispatch_once_t dOnce;
    dispatch_once(&dOnce, ^{
      df = [[NSDateFormatter alloc] init];
      df.dateFormat = @"MM-dd HH:mm:ss";
    });
    NSString *prev = [[NSUserDefaults standardUserDefaults] stringForKey:kAhaCrashKey];
    NSString *line = [NSString stringWithFormat:@"%@ %@",
        [df stringFromDate:[NSDate date]], detail ?: tag];
    // 只留最近 3 条，防无限膨胀
    NSMutableArray *arr = [prev ? [prev componentsSeparatedByString:@"\n----------\n"] : @[]
                            mutableCopy];
    [arr addObject:line];
    while (arr.count > 3) [arr removeObjectAtIndex:0];
    [[NSUserDefaults standardUserDefaults] setObject:
        [arr componentsJoinedByString:@"\n----------\n"] forKey:kAhaCrashKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
  } @catch (__unused NSException *e) { /* 崩溃记录失败就算了 */ }
}

static void ahaUncaughtHandler(NSException *exc) {
  ahaCrashRecord(@"exception",
      [NSString stringWithFormat:@"[未捕获异常] %@: %@\n堆栈:\n%@",
          exc.name, exc.reason, exc.callStackSymbols]);
}

static char gAhaSigPath[512];   // 信号处理器里只做 write，走安全路径
static void ahaSignalHandler(int sig) {
  const char *msg = "[AHA 段错误类崩溃] ";
  char buf[80];
  int fd = open(gAhaSigPath[0] ? gAhaSigPath : "/tmp/aha_crash.log",
                O_WRONLY | O_CREAT | O_APPEND, 0644);
  if (fd >= 0) {
    int n = snprintf(buf, sizeof(buf), "%s信号=%d（系统直接终止进程）\n", msg, sig);
    if (n > 0) write(fd, buf, (size_t)n);
    close(fd);
  }
  signal(sig, SIG_DFL);   // 恢复默认处理，让系统正常终止
  raise(sig);
}

static void ahaInstallCrashCatcher(void) {
  NSString *p = [NSString stringWithFormat:@"%@/aha_crash.log", NSHomeDirectory()];
  strncpy(gAhaSigPath, p.fileSystemRepresentation, sizeof(gAhaSigPath) - 1);
  NSSetUncaughtExceptionHandler(&ahaUncaughtHandler);
  signal(SIGABRT, &ahaSignalHandler);
  signal(SIGSEGV, &ahaSignalHandler);
  signal(SIGBUS,  &ahaSignalHandler);
  signal(SIGILL,  &ahaSignalHandler);
  signal(SIGTRAP, &ahaSignalHandler);
}

// 启动时读出上次崩溃记录，写进面板日志
static void ahaReportLastCrash(void) {
  // 面包屑（最关键：闪退前最后执行的步骤，哪一步死了直接可见）
  NSString *step = [[NSUserDefaults standardUserDefaults] stringForKey:@"aha_step_v1"];
  if (step.length) {
    ahaLog(@"e", [NSString stringWithFormat:@"⚠️ 上次闪退前最后步骤：【%@】", step]);
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"aha_step_v1"];
    [[NSUserDefaults standardUserDefaults] synchronize];
  }
  NSString *rec = [[NSUserDefaults standardUserDefaults] stringForKey:kAhaCrashKey];
  NSString *sig = nil;
  if (gAhaSigPath[0]) {
    NSData *d = [NSData dataWithContentsOfFile:@(gAhaSigPath)];
    if (d.length) {
      sig = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
      [[NSFileManager defaultManager] removeItemAtPath:@(gAhaSigPath) error:nil];  // 读后即清
    }
  }
  if (sig.length) {
    ahaLog(@"e", [NSString stringWithFormat:@"⚠️ 上次崩溃（信号级）：%@", sig]);
    ahaLog(@"e", @"请把这段日志截图发给开发者");
  }
  if (rec.length) {
    for (NSString *l in [rec componentsSeparatedByString:@"\n"]) ahaLog(@"e", l);
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kAhaCrashKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    ahaLog(@"e", @"↑ 上次闪退的根因已捕获，截图发给开发者");
  }
}

%ctor {
  ahaInstallCrashCatcher();  // 最先装，任何闪退都要留下证据
  %init(_ungrouped);         // 没这行，所有钩子都不生效（v0.2.0 血坑）
  // 6 秒后重装崩溃 handler：Shopee app 启动时会装自己的崩溃处理器把我们覆盖掉
  //（v0.5.5 崩了没日志的根因），覆盖回去才能持续抓到段错误证据
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
    ahaInstallCrashCatcher();
  });
  gPool = [AHAPool shared];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
    gUI = [AHAUI shared];
    [gUI boot];
    ahaReportLastCrash();    // 面板起来后第一时间汇报上次闪退根因
  });
}
