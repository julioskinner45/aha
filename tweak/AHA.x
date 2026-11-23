// AHA.x — Shopee app 内采集客户端（Theos / Logos，rootless arm64，cloud-build 编译）
//
// 流程：租用账号登录租户中枢 → 领单（自己名下的任务池）→ 在 app 内打开商品页 →
//       被动截获 app 自己收到的 get_pc 回包 → 提交（聚星直传或中枢代交）→ 成功计数
//
// 被动截获原理：往 NSURLSessionConfiguration.protocolClasses 追加一个只认
//   /api/v4/pdp/get_pc 的观察型 NSURLProtocol——app 自己的网络栈照常收发
//   （请求原样转发、回包原样回传给 app），我们只是留一份副本。不修改任何
//   请求/响应、不做任何防检测/隐藏越狱。
//
// 面板：app 内悬浮 WKWebView，加载 /var/jb/share/aha/aha-panel.html，
//   JS↔原生走 ahaCmd 消息桥，所有网络由原生发起。

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <Foundation/Foundation.h>

static NSString *const kAhaCfgKey = @"aha_cfg_v2";
static NSString *const kGetPcMark = @"api/v4/pdp/get_pc";
static NSString *const kInternalFlag = @"aha_internal";

@class AHAPool;
static WKWebView *gWeb = nil;
static AHAPool *gPool = nil;

static void ahaPushLog(NSString *msg, NSString *lv);
static void ahaPushState(void);
static NSString *AhaJsonStr(NSString *s);

#pragma mark - 捕获仓库（get_pc 回包副本）

@interface AHACapture : NSObject
+ (AHACapture *)shared;
- (void)storeBody:(NSString *)body forURL:(NSURL *)url;
- (NSString *)bodyForShop:(NSString *)shopId item:(NSString *)itemId;
@end

@implementation AHACapture {
  NSMutableDictionary *_store;  // @"shop|item" -> @{ body, at }
  dispatch_queue_t _q;
}
+ (AHACapture *)shared {
  static AHACapture *s; static dispatch_once_t once;
  dispatch_once(&once, ^{ s = [[AHACapture alloc] init]; });
  return s;
}
- (instancetype)init {
  if ((self = [super init])) {
    _store = [NSMutableDictionary dictionary];
    _q = dispatch_queue_create("aha.capture", DISPATCH_QUEUE_SERIAL);
  }
  return self;
}
- (NSString *)queryValue:(NSString *)key in:(NSString *)query {
  if (!query) return nil;
  for (NSString *pair in [query componentsSeparatedByString:@"&"]) {
    NSRange eq = [pair rangeOfString:@"="];
    if (eq.location == NSNotFound || eq.location + eq.length >= pair.length) continue;
    if ([[pair substringToIndex:eq.location] isEqualToString:key])
      return [pair substringFromIndex:eq.location + eq.length];
  }
  return nil;
}
- (void)storeBody:(NSString *)body forURL:(NSURL *)url {
  NSString *shop = [self queryValue:@"shop_id" in:url.query];
  NSString *item = [self queryValue:@"item_id" in:url.query];
  if (!shop || !item || !body) return;
  dispatch_async(_q, ^{
    self->_store[[NSString stringWithFormat:@"%@|%@", shop, item]] =
        @{ @"body": body, @"at": [NSDate date] };
  });
}
- (NSString *)bodyForShop:(NSString *)shopId item:(NSString *)itemId {
  __block NSString *out = nil;
  dispatch_sync(_q, ^{
    NSDictionary *e = self->_store[[NSString stringWithFormat:@"%@|%@", shopId, itemId]];
    if (e) out = e[@"body"];
  });
  return out;
}
@end

#pragma mark - 观察型 NSURLProtocol（只认 get_pc，其余请求一律不拦）

@interface AHACaptureProtocol : NSURLProtocol <NSURLSessionDataDelegate>
@property(nonatomic, strong) NSMutableData *buf;
@property(nonatomic, strong) NSURLSession *fwdSess;
@end

@implementation AHACaptureProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
  if ([NSURLProtocol propertyForKey:kInternalFlag inRequest:request]) return NO;
  NSString *u = request.URL.absoluteString ?: @"";
  return ([u rangeOfString:kGetPcMark].location != NSNotFound);
}
+ (BOOL)canInitWithTask:(NSURLSessionTask *)task { return NO; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }

- (void)startLoading {
  NSMutableURLRequest *req = [self.request mutableCopy];
  [NSURLProtocol setProperty:@YES forKey:kInternalFlag inRequest:req];

  NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
  cfg.timeoutIntervalForRequest = 30;
  // 内部转发请求带标记 → canInitWithRequest 返回 NO → 不会递归
  self.fwdSess = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];
  [[self.fwdSess dataTaskWithRequest:req] resume];
}

- (void)stopLoading {
  [self.fwdSess invalidateAndCancel];
  self.fwdSess = nil;
}

// —— 原样转发给 app，同时留副本 ——
- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)task
    didReceiveResponse:(NSURLResponse *)resp
    completionHandler:(void (^)(NSURLSessionResponseDisposition))h {
  [self.client URLProtocol:self didReceiveResponse:resp
        cacheStoragePolicy:NSURLCacheStorageNotAllowed];
  h(NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)task
        didReceiveData:(NSData *)data {
  [self.client URLProtocol:self didLoadData:data];
  if (!self.buf) self.buf = [NSMutableData data];
  [self.buf appendData:data];
}
- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)t
    didCompleteWithError:(NSError *)err {
  if (self.buf && !err) {
    NSString *body = [[NSString alloc] initWithData:self.buf encoding:NSUTF8StringEncoding];
    [[AHACapture shared] storeBody:body forURL:self.request.URL];
  }
  if (err) [self.client URLProtocol:self didFailWithError:err];
  else [self.client URLProtocol:self didFinishLoading];
}

@end

#pragma mark - 注入观察协议到所有会话配置

%hook NSURLSessionConfiguration
- (NSArray *)protocolClasses {
  NSArray *orig = %orig;
  if (!orig) return @[ AHACaptureProtocol.class ];
  if (![orig containsObject:AHACaptureProtocol.class]) {
    NSMutableArray *m = [orig mutableCopy];
    [m addObject:AHACaptureProtocol.class];
    return m;
  }
  return orig;
}
%end

#pragma mark - 池客户端（领单/浏览/截包/上传 状态机）

@interface AHAPool : NSObject
+ (AHAPool *)shared;
@property(nonatomic, strong) NSMutableDictionary *cfg;
@property(nonatomic, assign) BOOL running, connected, resting;
@property(nonatomic, assign) NSInteger taken, ok;
@property(nonatomic, copy) NSString *me, *token, *taskLine;
- (void)applyCmd:(NSString *)cmd data:(NSDictionary *)data;
- (NSDictionary *)stateSnapshot;
- (NSArray *)logsSnapshot;
- (void)helloTick;
@end

@implementation AHAPool {
  dispatch_queue_t _q;
  NSMutableArray *_logs;
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

- (void)saveCfg { [[NSUserDefaults standardUserDefaults] setObject:self.cfg forKey:kAhaCfgKey]; }

- (NSString *)base {
  NSString *s = self.cfg[@"server"] ?: @"";
  while ([s hasSuffix:@"/"]) s = [s substringToIndex:s.length - 1];
  return s;
}

- (NSDictionary *)stateSnapshot {
  return @{
    @"cfg": self.cfg ?: @{},
    @"conn": @(self.connected), @"me": self.me ?: @"",
    @"stats": @{ @"taken": @(self.taken), @"ok": @(self.ok),
                 @"running": @(self.running), @"resting": @(self.resting) },
    @"task": self.taskLine ?: @"",
  };
}

- (NSArray *)logsSnapshot {
  __block NSArray *out;
  dispatch_sync(_q, ^{ out = [_logs copy]; });
  return out ?: @[];
}

- (void)appendLog:(NSString *)lv msg:(NSString *)msg {
  dispatch_async(_q, ^{
    [self->_logs addObject:[NSString stringWithFormat:@"%@\t%@", lv ?: @"i", msg ?: @""]];
    if (self->_logs.count > 300)
      [self->_logs removeObjectsInRange:NSMakeRange(0, self->_logs.count - 300)];
  });
}

- (void)nativeAPI:(NSString *)path method:(NSString *)method body:(NSDictionary *)body
      done:(void (^)(NSDictionary *, NSError *))done {
  NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
      [NSURL URLWithString:[self.base stringByAppendingString:path]]];
  req.HTTPMethod = method ?: @"GET";
  req.timeoutInterval = 30;
  [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  if (self.token.length)
    [req setValue:[@"Bearer " stringByAppendingString:self.token]
        forHTTPHeaderField:@"Authorization"];
  if (body && ![req.HTTPMethod isEqualToString:@"GET"])
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

  static NSURLSession *sess = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    sess = [NSURLSession sessionWithConfiguration:
        [NSURLSessionConfiguration defaultSessionConfiguration]];
  });
  [[sess dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
    if (e) { done(nil, e); return; }
    id obj = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    done(([obj isKindOfClass:[NSDictionary class]] ? obj : @{}), nil);
  }] resume];
}

- (NSInteger)num:(NSString *)k def:(NSInteger)d {
  id v = self.cfg[k];
  NSInteger n = [v respondsToSelector:@selector(integerValue)] ? [v integerValue] : d;
  return n > 0 ? n : d;
}

- (void)applyCmd:(NSString *)cmd data:(NSDictionary *)data {
  dispatch_async(_q, ^{
    if ([cmd isEqualToString:@"get"]) { ahaPushState(); return; }
    if ([cmd isEqualToString:@"clearlog"]) { [self->_logs removeAllObjects]; ahaPushState(); return; }
    if ([cmd isEqualToString:@"reset"]) { self.taken = 0; self.ok = 0; self.taskLine = @""; ahaPushState(); return; }
    if ([cmd isEqualToString:@"save"] || [cmd isEqualToString:@"mini"]) {
      if (data) {
        for (NSString *k in @[@"server", @"user", @"pass", @"pid",
                              @"gapMin", @"gapMax", @"restEvery", @"restSec"]) {
          id v = data[k]; if (v != nil) self.cfg[k] = v;
        }
        for (NSString *k in @[@"autoTake", @"rest", @"mini"]) {
          id v = data[k]; if (v != nil) self.cfg[k] = v;
        }
        [self saveCfg];
        ahaPushLog(@"配置已保存（本机）", @"s");
      }
      ahaPushState();
      return;
    }
    if ([cmd isEqualToString:@"connect"]) { [self connect:nil]; return; }
    if ([cmd isEqualToString:@"start"]) {
      if (!self.token) { [self connect:^{ [self startLoop]; }]; return; }
      [self startLoop]; return;
    }
    if ([cmd isEqualToString:@"stop"]) { [self stopLoop]; return; }
    if ([cmd isEqualToString:@"take"]) {
      if (!self.token) { [self connect:^{ [self takeOnce]; }]; return; }
      [self takeOnce]; return;
    }
  });
}

- (void)connect:(void (^)(void))after {
  dispatch_async(_q, ^{
    NSString *u = [self.cfg[@"user"] stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceCharacterSet]];
    if (u.length == 0) { ahaPushLog(@"先填租用账号", @"w"); ahaPushState(); return; }
    self.taskLine = @"";
    [self nativeAPI:@"/api/login" method:@"POST"
        body:@{ @"name": u, @"pass": self.cfg[@"pass"] ?: @"" }
        done:^(NSDictionary *j, NSError *e) {
      dispatch_async(self->_q, ^{
        if (j && [j[@"ok"] boolValue]) {
          self.token = j[@"token"];
          self.me = [j[@"name"] isKindOfClass:[NSString class]] ? j[@"name"] : u;
          self.connected = YES;
          ahaPushLog([NSString stringWithFormat:@"已连接 %@（租户池已隔离）", self.me], @"s");
          ahaPushState();
          if (after) after();
        } else {
          self.connected = NO; self.token = nil;
          ahaPushLog([NSString stringWithFormat:@"登录失败：%@",
              j[@"error"] ?: (e.localizedDescription ?: @"网络不通")], @"e");
          ahaPushState();
        }
      });
    }];
  });
}

- (void)startLoop {
  if (self.running) return;
  self.running = YES; self.resting = NO;
  ahaPushLog(@"领单循环已开始", @"s");
  ahaPushState();
  [self helloTick];
  [self loopTick];
}

- (void)stopLoop {
  self.running = NO;
  ahaPushLog(@"循环已停止", @"w");
  ahaPushState();
}

- (void)helloTick {
  if (!self.running || !self.token) return;
  [self nativeAPI:@"/api/pool/hello" method:@"POST"
      body:@{ @"profileId": self.cfg[@"pid"] ?: @"" } done:nil];
}

- (void)loopTick {
  if (!self.running) { ahaPushState(); return; }
  dispatch_async(_q, ^{
    BOOL rest = [self.cfg[@"rest"] boolValue];
    if (rest) {
      ahaPushState();
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
          self->_q, ^{ [self loopTick]; });
      return;
    }
    [self takeOnce];
    double wait;
    NSInteger every = [self num:@"restEvery" def:0];
    if (every > 0 && self.taken > 0 && (self.taken % every) == 0 && !self.resting) {
      self.resting = YES;
      NSInteger rs = [self num:@"restSec" def:60];
      ahaPushLog([NSString stringWithFormat:@"进入休息 %ld 秒", (long)rs], @"w");
      wait = rs;
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)),
          self->_q, ^{ self.resting = NO; ahaPushLog(@"休息结束", @"s"); });
    } else {
      double lo = [self num:@"gapMin" def:8], hi = [self num:@"gapMax" def:20];
      if (hi < lo) hi = lo;
      wait = lo + arc4random_uniform((UInt32)(hi - lo + 1));
    }
    ahaPushState();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)),
        self->_q, ^{ [self loopTick]; });
  });
}

- (void)takeOnce {
  dispatch_async(_q, ^{
    if (!self.token) { ahaPushLog(@"未连接中枢", @"w"); ahaPushState(); return; }
    self.taskLine = @"领取中…";
    ahaPushState();
    [self nativeAPI:@"/api/pool/take" method:@"POST"
        body:@{ @"profileId": self.cfg[@"pid"] ?: @"" }
        done:^(NSDictionary *j, NSError *e) {
      dispatch_async(self->_q, ^{
        if (e) {
          ahaPushLog([NSString stringWithFormat:@"领单请求失败：%@", e.localizedDescription], @"e");
          self.taskLine = @""; ahaPushState(); return;
        }
        NSDictionary *t = j[@"task"];
        if (![t isKindOfClass:[NSDictionary class]] || !t.count) {
          ahaPushLog([NSString stringWithFormat:@"暂无任务（%@）", j[@"reason"] ?: @"empty"], @"w");
          self.taskLine = @""; ahaPushState(); return;
        }
        self.taken++;
        [self handleTask:t];
      });
    }];
  });
}

- (void)handleTask:(NSDictionary *)t {
  NSString *taskId = [NSString stringWithFormat:@"%@", t[@"id"] ?: @""];
  NSString *taskUrl = [NSString stringWithFormat:@"%@", t[@"taskUrl"] ?: @""];
  NSString *shopId = [NSString stringWithFormat:@"%@", t[@"shopId"] ?: @""];
  NSString *itemId = [NSString stringWithFormat:@"%@", t[@"itemId"] ?: @""];
  NSString *acct = [NSString stringWithFormat:@"%@", t[@"acct"] ?: @""];
  self.taskLine = [NSString stringWithFormat:@"#%@ [%@] item %@ · 打开商品",
      taskId, acct, itemId];
  ahaPushLog([NSString stringWithFormat:@"领到单 #%@ [%@] item %@ shop %@",
      taskId, acct, itemId, shopId], @"s");
  ahaPushState();

  // 1) 在 app 内打开商品页（universal link 会被 app 自己路由）
  NSString *pageUrl = [NSString stringWithFormat:
      @"https://shopee.tw/product/%@/%@", shopId, itemId];
  dispatch_async(dispatch_get_main_queue(), ^{
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:pageUrl]
        options:@{} completionHandler:^(BOOL ok) {
          if (!ok) ahaPushLog(@"商品页打开失败（链接被系统拦截）", @"e");
        }];
  });

  // 2) 轮询截获仓库等 get_pc 回包（最长 25 秒；睡在串行队列上，别的 hello 不受影响）
  __block NSString *body = nil;
  for (int i = 0; i < 50 && !body; i++) {
    [NSThread sleepForTimeInterval:0.5];
    body = [[AHACapture shared] bodyForShop:shopId item:itemId];
  }
  dispatch_async(_q, ^{
    if (!body) {
      ahaPushLog(@"25 秒内没等到商品回包（页面没打开或没加载完），任务回池", @"w");
      self.taskLine = @"";
      [self nativeAPI:@"/api/pool/report" method:@"POST"
          body:@{ @"taskId": taskId, @"profileId": self.cfg[@"pid"] ?: @"", @"status": @"skip" }
          done:nil];
      ahaPushState();
      return;
    }
    // 3) 提交：优先聚星直传，未确认回退中枢代交
    self.taskLine = [NSString stringWithFormat:@"#%@ · 上传中（%lu KB）",
        taskId, (unsigned long)[body lengthOfBytesUsingEncoding:NSUTF8StringEncoding] / 1024];
    ahaPushState();
    NSString *jxServer = [NSString stringWithFormat:@"%@", t[@"jxServer"] ?: @""];
    NSString *submitToken = [NSString stringWithFormat:@"%@", t[@"submitToken"] ?: @""];
    if (jxServer.length > 8 && submitToken.length > 8) {
      [self directSubmit:taskId taskUrl:taskUrl result:body jxServer:jxServer token:submitToken];
    } else {
      [self hubSubmit:taskId taskUrl:taskUrl result:body];
    }
  });
}

- (void)directSubmit:(NSString *)taskId taskUrl:(NSString *)taskUrl result:(NSString *)result
             jxServer:(NSString *)jxServer token:(NSString *)token {
  NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
      [NSURL URLWithString:[jxServer stringByAppendingString:@"/api/task/submit/v2"]]];
  req.HTTPMethod = @"POST";
  req.timeoutInterval = 60;
  [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  [req setValue:[@"Bearer " stringByAppendingString:token]
      forHTTPHeaderField:@"Authorization"];
  req.HTTPBody = [NSJSONSerialization dataWithJSONObject:
      @{ @"appVersion": @"vv2", @"url": taskUrl, @"result": result } options:0 error:nil];

  static NSURLSession *sess = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    sess = [NSURLSession sessionWithConfiguration:
        [NSURLSessionConfiguration defaultSessionConfiguration]];
  });
  [[sess dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
    dispatch_async(self->_q, ^{
      BOOL ok = NO;
      if (!e && d) {
        id o = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        id code = [o isKindOfClass:[NSDictionary class]]
            ? (o[@"code"] ?: [o valueForKeyPath:@"data.code"]) : nil;
        ok = [code isEqual:@200] || [code isEqual:@(200)];
      }
      if (ok) [self markOk:taskId via:@"聚星直传"];
      else {
        ahaPushLog(@"直传未确认成功，回退中枢代交", @"w");
        [self hubSubmit:taskId taskUrl:taskUrl result:result];
      }
    });
  }] resume];
}

- (void)hubSubmit:(NSString *)taskId taskUrl:(NSString *)taskUrl result:(NSString *)result {
  [self nativeAPI:@"/api/pool/submit" method:@"POST"
      body:@{ @"taskId": taskId, @"url": taskUrl, @"result": result,
              @"profileId": self.cfg[@"pid"] ?: @"" }
      done:^(NSDictionary *j, NSError *e) {
        dispatch_async(self->_q, ^{
          if (j && [j[@"ok"] boolValue]) [self markOk:taskId via:@"中枢代交"];
          else {
            ahaPushLog([NSString stringWithFormat:@"上传失败：%@（任务回池）",
                j[@"error"] ?: (e.localizedDescription ?: @"未知")], @"e");
            self.taskLine = @"";
            [self nativeAPI:@"/api/pool/report" method:@"POST"
                body:@{ @"taskId": taskId, @"profileId": self.cfg[@"pid"] ?: @"", @"status": @"skip" }
                done:nil];
            ahaPushState();
          }
        });
      }];
}

- (void)markOk:(NSString *)taskId via:(NSString *)via {
  self.ok++;
  self.taskLine = @"";
  ahaPushLog([NSString stringWithFormat:@"✅ 单子 %@ 已交（%@），成功数 %ld", taskId, via, (long)self.ok], @"s");
  ahaPushState();
}

@end

#pragma mark - 日志 / 状态推送到面板

static void ahaPushLog(NSString *msg, NSString *lv) {
  [gPool appendLog:(lv ?: @"i") msg:(msg ?: @"")];
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!gWeb) return;
    NSString *js = [NSString stringWithFormat:@"window.__ahaLog(%@, %@);",
        AhaJsonStr(msg), AhaJsonStr(lv ?: @"i")];
    [gWeb evaluateJavaScript:js completionHandler:nil];
  });
}

static void ahaPushState(void) {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!gWeb || !gPool) return;
    NSMutableDictionary *s = [[gPool stateSnapshot] mutableCopy];
    s[@"lastLogs"] = [gPool logsSnapshot];
    NSData *d = [NSJSONSerialization dataWithJSONObject:s options:0 error:nil];
    if (!d) return;
    NSString *js = [NSString stringWithFormat:@"window.__ahaState(%@);",
        [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding]];
    [gWeb evaluateJavaScript:js completionHandler:nil];
  });
}

static NSString *AhaJsonStr(NSString *s) {
  NSData *d = [NSJSONSerialization dataWithJSONObject:(s ?: @"") options:0 error:nil];
  return d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"\"\"";
}

#pragma mark - 悬浮面板（可拖动 / 可收起 / 可重开）

@interface UIControlBlock : NSObject
@property(nonatomic, copy) void (^blk)(void);
@end
@implementation UIControlBlock
- (void)fire { if (self.blk) self.blk(); }
@end
static void ahaAddTargetBlock(UIControl *c, void (^blk)(void)) {
  UIControlBlock *wrap = [[UIControlBlock alloc] init];
  wrap.blk = blk;
  objc_setAssociatedObject(c, &wrap, wrap, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  [c addTarget:wrap action:@selector(fire) forControlEvents:UIControlEventTouchUpInside];
}

@interface AHABox : UIView
@end
@implementation AHABox
- (void)ahaDrag:(UIPanGestureRecognizer *)g {
  static CGPoint origin;
  if (g.state == UIGestureRecognizerStateBegan) origin = self.center;
  if (g.state == UIGestureRecognizerStateChanged) {
    CGPoint t = [g translationInView:self];
    self.center = CGPointMake(origin.x + t.x, origin.y + t.y);
  }
}
@end

@interface AHABridge : NSObject <WKScriptMessageHandler>
@end
@implementation AHABridge
- (void)userContentController:(WKUserContentController *)ucc
      didReceiveScriptMessage:(WKScriptMessage *)msg {
  if (![msg.name isEqualToString:@"ahaCmd"]) return;
  if (![msg.body isKindOfClass:[NSDictionary class]]) return;
  NSString *cmd = msg.body[@"cmd"];
  NSDictionary *data = [msg.body[@"data"] isKindOfClass:[NSDictionary class]]
      ? msg.body[@"data"] : nil;
  if (!cmd) return;
  [gPool applyCmd:cmd data:data];
}
@end

static void ahaBuildPanel(void) {
  UIWindow *key = nil;
  for (UIWindow *win in [UIApplication sharedApplication].windows)
    if (win.isKeyWindow) { key = win; break; }
  if (!key) key = [UIApplication sharedApplication].windows.firstObject;
  if (!key) return;

  CGRect scr = key.bounds;
  CGFloat w = 300, h = 460;

  WKWebViewConfiguration *wcfg = [[WKWebViewConfiguration alloc] init];
  WKUserContentController *ucc = [[WKUserContentController alloc] init];
  [ucc addScriptMessageHandler:[[AHABridge alloc] init] name:@"ahaCmd"];
  wcfg.userContentController = ucc;

  WKWebView *wv = [[WKWebView alloc] initWithFrame:CGRectMake(0, 30, w, h - 30)
      configuration:wcfg];
  wv.scrollView.bounces = NO;
  gWeb = wv;

  AHABox *box = [[AHABox alloc] initWithFrame:CGRectMake(14, scr.size.height * 0.12, w, h)];
  box.backgroundColor = [UIColor colorWithWhite:0.06 alpha:0.97];
  box.layer.cornerRadius = 12;
  box.clipsToBounds = YES;
  box.layer.borderWidth = 1;
  box.layer.borderColor = [UIColor colorWithRed:1 green:1 blue:1 alpha:0.14].CGColor;

  UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 30)];
  bar.backgroundColor = [UIColor colorWithRed:0.23 green:0.51 blue:0.96 alpha:1];
  UILabel *lb = [[UILabel alloc] initWithFrame:CGRectMake(10, 0, w - 70, 30)];
  lb.text = @"⠿ AHA";
  lb.textColor = [UIColor whiteColor];
  lb.font = [UIFont boldSystemFontOfSize:13];
  [bar addSubview:lb];
  UIButton *miniBtn = [UIButton buttonWithType:UIButtonTypeCustom];
  miniBtn.frame = CGRectMake(w - 40, 0, 40, 30);
  [miniBtn setTitle:@"—" forState:UIControlStateNormal];
  [miniBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
  [bar addSubview:miniBtn];

  UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
      initWithTarget:box action:@selector(ahaDrag:)];
  [bar addGestureRecognizer:pan];

  UIButton *tab = [UIButton buttonWithType:UIButtonTypeCustom];
  tab.frame = CGRectMake(scr.size.width - 58, scr.size.height * 0.28, 48, 30);
  [tab setTitle:@"AHA" forState:UIControlStateNormal];
  tab.backgroundColor = [UIColor colorWithRed:0.23 green:0.51 blue:0.96 alpha:0.92];
  tab.layer.cornerRadius = 6;
  tab.hidden = YES;

  __block UIView *b = box;
  __block UIButton *t = tab;
  ahaAddTargetBlock(miniBtn, ^{ b.hidden = YES; t.hidden = NO; });
  ahaAddTargetBlock(tab, ^{ b.hidden = NO; t.hidden = YES; });

  [box addSubview:bar];
  [box addSubview:wv];
  [key addSubview:box];
  [key addSubview:tab];

  NSString *htmlPath = @"/var/jb/share/aha/aha-panel.html";
  if ([[NSFileManager defaultManager] fileExistsAtPath:htmlPath]) {
    NSString *html = [NSString stringWithContentsOfFile:htmlPath
        encoding:NSUTF8StringEncoding error:nil];
    if (html) [wv loadHTMLString:html baseURL:[NSURL URLWithString:@"https://local.aha/"]];
  }

  // 心跳 10s：中枢 hello（保持在线窗口计数）
  [NSTimer scheduledTimerWithTimeInterval:10 repeats:YES block:^(__unused NSTimer *x) {
    if (gPool.running && gPool.token) [gPool helloTick];
  }];
}

%ctor {
  gPool = [AHAPool shared];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        ahaBuildPanel();
        ahaPushState();
        ahaPushLog(@"AHA 已注入 Shopee app（被动观察模式）", @"s");
      });
}
