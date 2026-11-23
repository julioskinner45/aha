// AHA.x — Shopee app 内采集客户端 v0.5.0（App 内路由导航 + 键盘完成条 + 休息折叠）
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

static NSString *const kAhaCfgKey = @"aha_cfg_v2";
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
@property(nonatomic, assign) BOOL running, connected, resting, risk;
@property(nonatomic, assign) NSInteger taken, ok;
@property(nonatomic, copy) NSString *me, *token, *taskLine;
@property(nonatomic, readonly) dispatch_queue_t q;
- (void)connect:(void (^)(void))after;
- (void)startLoop;
- (void)stopLoop;
- (void)helloTick;
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

  // —— 风控识别（Ajie 同款判据）——
  if (code == 403 || [body containsString:@"90309999"]) {
    ahaLog(@"e", @"⛔ 命中风控墙（HTTP 403 / 90309999）——建议暂停歇会");
    if (gPool) { dispatch_async(gPool.q, ^{ gPool.risk = YES; }); ahaRefreshUI(); }
    return;
  }
  if ([body containsString:@"266900002"]) {
    ahaLog(@"w", @"⚠️ get_pc 报 266900002（风控前置信号）");
    if (gPool) { dispatch_async(gPool.q, ^{ gPool.risk = YES; }); ahaRefreshUI(); }
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

#pragma mark - App 内路由导航（Ajie 实证做法：Shopee 自带 SHPNavigator，绝不跳出 app）

// 拿我们自己的悬浮窗（AHAUI 在后面才实现，属性走运行时取）
static UIWindow *ahaOwnWin(void) {
  if (!gUI) return nil;
  SEL s = NSSelectorFromString(@"win");
  if (![(id)gUI respondsToSelector:s]) return nil;
  return ((id(*)(id, SEL))objc_msgSend)((id)gUI, s);
}

// 找 Shopee 自己窗口的当前 VC（跳过我们的悬浮窗）
static UIViewController *ahaTopVC(void) {
  UIViewController *fallback = nil;
  UIWindow *own = ahaOwnWin();
  for (UIWindow *w in [UIApplication sharedApplication].windows) {
    if (w == own) continue;
    UIViewController *vc = w.rootViewController;
    if (!vc) continue;
    if (!fallback) fallback = vc;
    if (w.isKeyWindow) {
      while (vc.presentedViewController) vc = vc.presentedViewController;
      if ([vc isKindOfClass:[UINavigationController class]]) {
        UIViewController *t = [(UINavigationController *)vc topViewController];
        if (t) vc = t;
      }
      return vc;
    }
  }
  return fallback;
}

// 找 Shopee 自己的导航控制器（收弹层/控栈深用）
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

// navigateOption/pushOption/completion 三个参数只敢传对象或标量（按 0/nil），结构体参数直接放弃该选择器
static BOOL ahaArgTypeOk(NSMethodSignature *sig, NSUInteger idx) {
  if (sig.numberOfArguments <= idx) return NO;
  const char *t = [sig getArgumentTypeAtIndex:idx];
  if (!t || !t[0]) return NO;
  switch (t[0]) {
    case '@': case 'q': case 'Q': case 'i': case 'I': case 'l': case 'L':
    case 's': case 'S': case 'c': case 'C': case 'Z': case 'B':
      return YES;
    default:
      return NO;
  }
}

// Ajie 的路由链（从它 dylib 里挖的候选）：SHPNavigator 单例 + SHPNavigatorNavigationPath
// 路径串 rn/PRODUCT_PAGE?item_id=X&shop_id=Y —— Shopee 内部 RN 页面路由，页面在 app 里 push
static BOOL ahaNavInApp(NSString *shopId, NSString *itemId) {
  Class navCls  = NSClassFromString(@"SHPNavigator");
  Class pathCls = NSClassFromString(@"SHPNavigatorNavigationPath");
  if (!navCls || !pathCls) return NO;
  @try {
    id nav = nil;
    for (NSString *m in @[@"sharedInstance", @"sharedManager", @"defaultManager", @"manager",
                          @"shared", @"navigator", @"navigationManager", @"navigatorManager"]) {
      SEL s = NSSelectorFromString(m);
      if ([navCls respondsToSelector:s]) {
        nav = ((id(*)(id, SEL))objc_msgSend)(navCls, s);
        if (nav) break;
      }
    }
    if (!nav) return NO;

    NSString *route = [NSString stringWithFormat:@"rn/PRODUCT_PAGE?item_id=%@&shop_id=%@", itemId, shopId];
    id path = nil;
    id (*msgObj)(id, SEL, id) = (id(*)(id, SEL, id))objc_msgSend;
    for (NSString *m in @[@"pathWithString:", @"navigationPathWithString:", @"pathWithRoute:", @"pathWithAppRL:"]) {
      SEL s = NSSelectorFromString(m);
      if ([pathCls respondsToSelector:s]) { path = msgObj(pathCls, s, route); if (path) break; }
    }
    if (!path) {
      id p = [[pathCls alloc] init];
      for (NSString *m in @[@"initWithString:", @"initWithRoute:", @"initWithAppRL:"]) {
        SEL s = NSSelectorFromString(m);
        if ([p respondsToSelector:s]) { path = msgObj(p, s, route); break; }
      }
      if (!path) return NO;
    }

    UIViewController *vc = ahaTopVC();
    if (!vc) return NO;

    // 防堆叠黑屏：失败商品页会弹「OK」白板弹层、还会一层层 push，
    // 先收掉弹层；导航栈超过 2 层（根+1 商品页）就回根再跳，栈内不超限就从当前页直接跳
    UINavigationController *nc = ahaShopeeNav();
    if (nc) {
      if (nc.presentedViewController) [nc dismissViewControllerAnimated:NO completion:nil];
      if (nc.viewControllers.count > 2) [nc popToRootViewControllerAnimated:NO];
      UIViewController *top = nc.topViewController;
      if (top) vc = top;
    } else if (vc.presentedViewController) {
      [vc dismissViewControllerAnimated:NO completion:nil];
    }

    for (NSString *m in @[@"navigateFromViewController:destinationPath:navigateOption:completion:",
                          @"pushFromViewController:destinationPath:pushOption:completion:"]) {
      SEL sel = NSSelectorFromString(m);
      if (![nav respondsToSelector:sel]) continue;
      NSMethodSignature *sig = [navCls instanceMethodSignatureForSelector:sel];
      if (!ahaArgTypeOk(sig, 2) || !ahaArgTypeOk(sig, 3) || !ahaArgTypeOk(sig, 4)) continue;
      void (*fn)(id, SEL, id, id, id, id) = (void (*)(id, SEL, id, id, id, id))objc_msgSend;
      fn(nav, sel, vc, path, nil, nil);
      return YES;
    }
  } @catch (NSException *e) {
    ahaLog(@"w", [NSString stringWithFormat:@"App 内导航异常：%@", e.reason]);
    return NO;
  }
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
  return [NSString stringWithFormat:@"领 %ld · 成 %ld", (long)self.taken, (long)self.ok];
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
    done(([obj isKindOfClass:[NSDictionary class]] ? obj : @{}), e);
  }] resume];
}

// —— 登录（敞口：只发账号名，无密码；中枢 /api/pool/login 发池专用 token）——
- (void)connect:(void (^)(void))after {
  NSString *u = [self.cfg[@"user"] stringByTrimmingCharactersInSet:
      [NSCharacterSet whitespaceCharacterSet]];
  if (u.length == 0) { ahaLog(@"w", @"先填账号"); ahaRefreshUI(); return; }
  self.taskLine = @"";
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
    // 休息窗口（每 restEvery 单歇 restSec 秒；两项都设了才生效）
    NSInteger every = [self num:@"restEvery" def:0];
    NSInteger rs = [self num:@"restSec" def:0];
    if (every > 0 && rs > 0 && self.taken > 0 && (self.taken % every) == 0 && !self.resting) {
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
          ahaLog(@"e", [NSString stringWithFormat:@"领单失败：%@", e.localizedDescription]);
          self.taskLine = @"";
          ahaRefreshUI();
          [self scheduleNext:5];
          return;
        }
        NSDictionary *t = j[@"task"];
        if (![t isKindOfClass:[NSDictionary class]] || !t.count) {
          double wait = [j[@"waitMs"] isKindOfClass:[NSNumber class]]
              ? [j[@"waitMs"] doubleValue] / 1000.0 : 0;
          if (wait < 1) wait = [self randomGap];
          self.taskLine = @"";
          ahaRefreshUI();
          [self scheduleNext:wait];
          return;
        }
        self.taken++;
        [self handleTask:t];
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
  ahaLog(@"s", [NSString stringWithFormat:@"领到单 #%@ [%@] item %@ shop %@", taskId, acct, itemId, shopId]);
  ahaRefreshUI();

  // App 内路由导航（Ajie 同款：SHPNavigator push 商品页，不跳出 app）；
  // 路由没打通才退回网页兜底并明确提示
  dispatch_async(dispatch_get_main_queue(), ^{
    if (ahaNavInApp(shopId, itemId)) {
      ahaLog(@"i", @"已在 app 内打开商品页");
      return;
    }
    ahaLog(@"w", @"App 内路由不可用，回退网页打开（请把日志发我）");
    [[UIApplication sharedApplication] openURL:
        [NSURL URLWithString:[NSString stringWithFormat:@"https://shopee.tw/product/%@/%@", shopId, itemId]]
        options:@{} completionHandler:nil];
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
    }
    NSString *via = @"app截包";
    if (!body) {
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
        if (!e && d) {
          id o = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
          id code = [o isKindOfClass:[NSDictionary class]] ? (o[@"code"] ?: [o valueForKeyPath:@"data.code"]) : nil;
          ok = [code isEqual:@200] || [code isEqual:@(200)];
        }
        if (ok) [self markOk:taskId via:@"聚星直传"];
        else [self hubSubmit:taskId taskUrl:taskUrl result:result];
      });
    }] resume];
  } else {
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
@property(nonatomic, strong) UITextView *logView;
@property(nonatomic, strong) UIButton *gearBtn, *miniBtn, *startBtn, *resetBtn, *restBtn;
- (void)boot;
- (void)layoutPanel;
- (void)toggleRest;
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
  if ([gPool num:@"restEvery" def:0] > 0) self.restRow.hidden = NO;
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

// 休息折叠按钮：点开/收起「做N单休M分钟」
- (void)toggleRest {
  self.restRow.hidden = !self.restRow.hidden;
  [self updateRestTitle];
  [self layoutPanel];
}
- (void)updateRestTitle {
  NSInteger every = MAX([self.restEveryField.text integerValue], 0);
  NSInteger mins  = MAX([self.restSecField.text integerValue], 0);
  NSString *t = every > 0
      ? [NSString stringWithFormat:@"☕ 休息：每 %ld 单休 %ld 分钟", (long)every, (long)mins]
      : @"☕ 休息：未开启";
  [self.restBtn setTitle:t forState:UIControlStateNormal];
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
    self.miniInfo.text = [NSString stringWithFormat:@"%ld/%ld", (long)gPool.taken, (long)gPool.ok];
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
  if (!self.restRow.hidden) {                 // 休息展开：两个框 + 下推内容
    self.restRow.frame = CGRectMake(12, y, w - 24, 32);
    self.restEveryField.frame = CGRectMake(0, 0, fw, 32);
    self.restSecField.frame   = CGRectMake(fw + 8, 0, fw, 32);
    y += 40;
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
  self.miniInfo.text = [NSString stringWithFormat:@"%ld/%ld", (long)gPool.taken, (long)gPool.ok];
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

%ctor {
  %init(_ungrouped);         // 没这行，所有钩子都不生效（v0.2.0 血坑）
  gPool = [AHAPool shared];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
    gUI = [AHAUI shared];
    [gUI boot];
  });
}
