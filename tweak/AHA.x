// AHA.x — Shopee app 内采集客户端 v0.3.0（照 Ajie 0.1.3 实证架构重写）
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
//   header 可拖动 · ⚙设置（服务器/密码/休息） · — 收起成小球
//   状态条 / 计数 / 任务行 · 账号输入框 · 间隔输入框 · 登录/开始/停止/清零
//   UITextView 日志窗（等宽字体自动滚底） · 右下角拉拽改面板大小
//
// 全被动：不改任何请求/响应、不做检测绕过、不隐藏越狱。

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

static NSString *const kAhaCfgKey = @"aha_cfg_v2";
static NSString *const kPdpMark   = @"/api/v4/pdp/";
static NSString *const kGetPcMark = @"/api/v4/pdp/get_pc";
// get_pc 直取模板（Ajie 同款：display_model_id=0 / model_selection_logic=3 / tz 480）
static NSString *const kGetPcTpl  = @"https://shopee.tw/api/v4/pdp/get_pc?display_model_id=0&item_id=%@&model_selection_logic=3&shop_id=%@&tz_offset_in_minutes=480&detail_level=0";

@class AHACapture;
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
    sess = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]];
  });
  [[sess dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
    id obj = (d && !e) ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    done(([obj isKindOfClass:[NSDictionary class]] ? obj : @{}), e);
  }] resume];
}

// —— 登录 ——
- (void)connect:(void (^)(void))after {
  NSString *u = [self.cfg[@"user"] stringByTrimmingCharactersInSet:
      [NSCharacterSet whitespaceCharacterSet]];
  if (u.length == 0) { ahaLog(@"w", @"先填租用账号"); ahaRefreshUI(); return; }
  self.taskLine = @"";
  [self api:@"/api/login" method:@"POST"
      body:@{ @"name": u, @"pass": self.cfg[@"pass"] ?: @"" }
      done:^(NSDictionary *j, NSError *e) {
    dispatch_async(self.q, ^{
      if (j && [j[@"ok"] boolValue]) {
        self.token = j[@"token"];
        self.me = [j[@"name"] isKindOfClass:[NSString class]] ? j[@"name"] : u;
        self.connected = YES;
        ahaLog(@"s", [NSString stringWithFormat:@"已连接 %@（租户池隔离）", self.me]);
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

// —— 调度 ——
- (double)randomGap {
  double lo = [self num:@"gapMin" def:8], hi = [self num:@"gapMax" def:20];
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
    // 休息窗口（每 restEvery 单歇 restSec 秒）
    NSInteger every = [self num:@"restEvery" def:0];
    if (every > 0 && self.taken > 0 && (self.taken % every) == 0 && !self.resting) {
      NSInteger rs = [self num:@"restSec" def:60];
      self.resting = YES;
      ahaLog(@"w", [NSString stringWithFormat:@"已领 %ld 单，休息 %ld 秒", (long)self.taken, (long)rs]);
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

  NSString *pageUrl = [NSString stringWithFormat:@"https://shopee.tw/product/%@/%@", shopId, itemId];
  dispatch_async(dispatch_get_main_queue(), ^{
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:pageUrl]
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
  [[NSURLSession sessionWithConfiguration:
      [NSURLSessionConfiguration ephemeralSessionConfiguration]]
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
      sess = [NSURLSession sessionWithConfiguration:
          [NSURLSessionConfiguration defaultSessionConfiguration]];
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
  objc_setAssociatedObject(c, w, w, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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

// 面板容器：header 拖动 + 右下角 resize
@interface AHAPanel : UIView @end
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
    CGFloat w = MIN(MAX(w0 + t.x, 260), scrW - 20);
    CGFloat h = MIN(MAX(h0 + t.y, 300), scrH - 40);
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

@interface AHAUI : NSObject
@property(nonatomic, strong) AHAPassthroughWindow *win;
@property(nonatomic, strong) AHAPanel *panel;
@property(nonatomic, strong) UIView *header, *mini;
@property(nonatomic, strong) UILabel *ttl, *statusLabel, *taskLabel, *counterLabel, *miniInfo, *rh;
@property(nonatomic, strong) UITextField *userField, *gapField;
@property(nonatomic, strong) UITextView *logView;
@property(nonatomic, strong) UIButton *gearBtn, *miniBtn, *loginBtn, *startBtn, *stopBtn, *resetBtn;
- (void)boot;
- (void)layoutPanel;
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
  if (w < 260 || w > scr.size.width) w = 300;
  if (h < 300 || h > scr.size.height) h = 380;
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

  // 状态 / 计数 / 任务行
  self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 48, w - 24, 18)];
  self.statusLabel.font = [UIFont systemFontOfSize:12];
  self.counterLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 68, w - 24, 18)];
  self.counterLabel.font = [UIFont boldSystemFontOfSize:12];
  self.counterLabel.textColor = AhaColor(120, 200, 255, 1);
  self.taskLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 88, w - 24, 18)];
  self.taskLabel.font = [UIFont systemFontOfSize:11];
  self.taskLabel.textColor = AhaColor(255, 255, 255, 0.55);
  [p addSubview:self.statusLabel];
  [p addSubview:self.counterLabel];
  [p addSubview:self.taskLabel];

  // 账号 + 间隔输入
  self.userField = AhaField(@"租用账号（中枢后台开的）", @"👤");
  self.gapField  = AhaField(@"间隔秒，如 8-20", @"⏱");
  self.gapField.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
  [p addSubview:self.userField];
  [p addSubview:self.gapField];

  // 按钮行
  self.loginBtn = AhaBtn(@"登录", AhaColor(35, 100, 235, 1), 13);
  self.startBtn = AhaBtn(@"开始", AhaColor(34, 160, 84, 1), 13);
  self.stopBtn  = AhaBtn(@"停止", AhaColor(200, 60, 56, 1), 13);
  self.resetBtn = AhaBtn(@"清零", AhaColor(90, 96, 108, 1), 13);
  for (UIButton *b in @[self.loginBtn, self.startBtn, self.stopBtn, self.resetBtn]) [p addSubview:b];

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
  ahaTap(self.miniBtn,  ^{ [[AHAUI shared] collapse:YES]; });
  ahaTap(self.loginBtn, ^{ [gPool connect:nil]; });
  ahaTap(self.startBtn, ^{ [gPool startLoop]; });
  ahaTap(self.stopBtn,  ^{ [gPool stopLoop]; });
  ahaTap(self.resetBtn, ^{ [gPool resetCounters]; ahaLog(@"i", @"计数已清零"); });

  // 输入框预填 + 失焦保存
  self.userField.text = gPool.cfg[@"user"] ?: @"";
  NSInteger lo = [gPool num:@"gapMin" def:8], hi = [gPool num:@"gapMax" def:20];
  self.gapField.text = [NSString stringWithFormat:@"%ld-%ld", (long)lo, (long)hi];
  [self.userField addTarget:self action:@selector(fieldsChanged) forControlEvents:UIControlEventEditingDidEnd];
  [self.gapField addTarget:self action:@selector(fieldsChanged) forControlEvents:UIControlEventEditingDidEnd];

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
  gPool.cfg[@"user"] = self.userField.text ?: @"";
  NSString *s = [self.gapField.text stringByReplacingOccurrencesOfString:@" " withString:@""];
  NSArray *parts = [s componentsSeparatedByString:@"-"];
  NSInteger lo = [parts.firstObject integerValue];
  NSInteger hi = parts.count > 1 ? [parts[1] integerValue] : 0;
  if (lo > 0) gPool.cfg[@"gapMin"] = @(lo);
  if (hi >= lo && hi > 0) gPool.cfg[@"gapMax"] = @(hi);
  [gPool saveCfg];
  ahaLog(@"i", @"配置已保存（本机）");
}

- (void)showSettings {
  UIAlertController *a = [UIAlertController alertControllerWithTitle:@"AHA 设置"
      message:nil preferredStyle:UIAlertControllerStyleAlert];
  [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
    f.placeholder = @"服务器地址";
    f.text = gPool.cfg[@"server"] ?: @"";
  }];
  [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
    f.placeholder = @"密码";
    f.secureTextEntry = YES;
    f.text = gPool.cfg[@"pass"] ?: @"";
  }];
  [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
    f.placeholder = @"休息：每 N 单（0=不歇）";
    f.keyboardType = UIKeyboardTypeNumberPad;
    f.text = [NSString stringWithFormat:@"%ld",
        (long)(gPool.cfg[@"restEvery"] ? [gPool.cfg[@"restEvery"] integerValue] : 0)];
  }];
  [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
    f.placeholder = @"休息秒数";
    f.keyboardType = UIKeyboardTypeNumberPad;
    f.text = [NSString stringWithFormat:@"%ld",
        (long)(gPool.cfg[@"restSec"] ? [gPool.cfg[@"restSec"] integerValue] : 60)];
  }];
  [a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *act) {
    NSString *sv = a.textFields[0].text ?: @"";
    if (sv.length) gPool.cfg[@"server"] = sv;
    gPool.cfg[@"pass"] = a.textFields[1].text ?: @"";
    NSInteger ev = [a.textFields[2].text integerValue];
    NSInteger rs = [a.textFields[3].text integerValue];
    gPool.cfg[@"restEvery"] = @(MAX(ev, 0));
    gPool.cfg[@"restSec"] = @(rs > 0 ? rs : 60);
    [gPool saveCfg];
    ahaLog(@"i", @"设置已保存");
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
  self.statusLabel.frame  = CGRectMake(12, 48, w - 24, 18);
  self.counterLabel.frame = CGRectMake(12, 68, w - 24, 18);
  self.taskLabel.frame    = CGRectMake(12, 88, w - 24, 18);
  CGFloat fw = (w - 12 * 2 - 8) / 2;
  self.userField.frame = CGRectMake(12, 112, fw, 34);
  self.gapField.frame  = CGRectMake(12 + fw + 8, 112, fw, 34);
  CGFloat bw = (w - 12 * 2 - 3 * 6) / 4;
  self.loginBtn.frame = CGRectMake(12,               152, bw, 30);
  self.startBtn.frame = CGRectMake(12 + (bw + 6),    152, bw, 30);
  self.stopBtn.frame  = CGRectMake(12 + (bw + 6) * 2, 152, bw, 30);
  self.resetBtn.frame = CGRectMake(12 + (bw + 6) * 3, 152, bw, 30);
  self.logView.frame  = CGRectMake(12, 188, w - 24, h - 188 - 14);
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

#pragma mark - 入口（显式 %ctor 必须手动 %init —— v0.2.0 的血坑）

%ctor {
  %init;                     // 没这行，所有 %hook 都不生效
  gPool = [AHAPool shared];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
    gUI = [AHAUI shared];
    [gUI boot];
  });
}
