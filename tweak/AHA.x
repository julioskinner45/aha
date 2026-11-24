// AHA.x — Shopee app 内采集客户端 v0.5.14（导航 = Ajie 逐字复刻 + 面包屑诊断）
//
// v0.5.6 关键改动（对照 Ajie 0.1.3 反汇编逐条对齐）：
// v0.5.13（2026-11-24）：导航/风控/日志/验券 全面对照 Ajie 反汇编 1:1 重做——
//   导航=openCurrentTask 时序（popToRoot→0.35s→内路由→失败 Universal Link openURL 兜底，不再 Direct PDP 当导航用）；
//   风控=删弹窗，266900002 按正常响应提交，90309999 自动停，直连失败不计风控，连续 2 次无数据自动暂停；
//   日志=[HH:mm:ss] 时间戳+去噪（第三方挂钩/观察窗不再刷屏）+0.25s 合并刷新修乱跳；
//   验券=优惠券检测（start/report 契约 1:1，设置里填后端用户ID开启）
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

// MSHookMessageEx（substrate）：Ajie delegate 动态 swizzle 同款，不 import substrate.h 直接声明
extern void MSHookMessageEx(Class _class, SEL message, IMP hook, IMP *result);

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
// v0.5.22 纯净模式开关（aha_pure_v1，默认开）：二分定位「装上即全网死」——
// 纯净 = 不装任何网络钩子 + 不装崩溃捕获器；完整 = 功能全装。切换后需重启虾皮生效
static BOOL gPure = YES;

static void ahaLog(NSString *lv, NSString *msg);          // 写日志 + 面板滚动
// 观察窗：打开商品页后 30s 内记录 app 发出的每条虾皮请求（诊断「页面开了但没回包」）
// v0.5.16：去重收集 host+path（pdp/get_pc 保留 query），窗口结束/超时一次性刷出——
// 这次要回答「导航后 app 到底请求了什么端点」：如果列表里没有任何 pdp 端点，
// 说明 get_pc 路径假设是错的或者请求根本没发；有端点但没抓到=匹配规则错
static NSDate *gObserveUntil = nil;
static NSInteger gObsCount = 0;
static NSInteger gObsAny = 0;      // v0.5.18：窗口内全部请求（不限域名）
static NSInteger gObsShopee = 0;   // 窗口内虾皮域名请求
static NSInteger gObsJSON = 0;     // 窗口内 NSJSON 解析次数
static NSInteger gObsRecv = 0;     // v0.5.19：窗口内回包事件（completionHandler + delegate）
static void ahaObserveRecv(void) {
  if (gObserveUntil && [gObserveUntil compare:[NSDate date]] == NSOrderedAscending) gObsRecv++;
}
static NSMutableArray *gObsURLs = nil;
static BOOL gObsFlushed = NO;
static void ahaObserveFlush(void) {
  if (gObsFlushed) return;
  gObsFlushed = YES;
  // v0.5.28 Ajie 风格精简：观察窗只做静默收集，不再刷屏（采集链路已通，诊断期结束）
  [gObsURLs removeAllObjects];
}
static void ahaObserveBegin(void) {
  gObserveUntil = [NSDate dateWithTimeIntervalSinceNow:30];
  gObsCount = 0; gObsAny = 0; gObsShopee = 0; gObsJSON = 0; gObsRecv = 0; gObsFlushed = NO;
  if (!gObsURLs) gObsURLs = [NSMutableArray array]; else [gObsURLs removeAllObjects];
}
static void ahaObserveURL(NSString *u) {
  if (!gObserveUntil || [gObserveUntil compare:[NSDate date]] == NSOrderedAscending) {
    if (!gObsFlushed) ahaObserveFlush();          // 窗口自然到期 → 惰性刷出
    return;
  }
  if (u.length) gObsAny++;                        // v0.5.18：全域名计数
  if (gObsCount >= 60) return;
  if (!u || u.length == 0) return;
  NSURL *uu = [NSURL URLWithString:u];
  NSString *host = uu.host ?: @"";
  if (![host containsString:@"shopee"]) return;
  gObsShopee++;
  gObsCount++;
  NSString *path = [NSString stringWithFormat:@"%@%@", host, uu.path ?: @""];
  NSString *q = uu.query ?: @"";
  if (q.length && ([path containsString:@"pdp"] || [path containsString:@"get_pc"]))
    path = [NSString stringWithFormat:@"%@?%@", path, q.length > 80 ? [q substringToIndex:80] : q];
  if (path.length > 130) path = [[path substringToIndex:130] stringByAppendingString:@"…"];
  if (![gObsURLs containsObject:path] && gObsURLs.count < 24) [gObsURLs addObject:path];
}
// v0.5.28：诊断期结束，会话 delegate 类名探针已删（采集链路已通）
static void ahaRefreshUI(void);                           // 主线程刷面板

#pragma mark - 池客户端（接口声明）

@interface AHAPool : NSObject
@property(nonatomic, strong) NSMutableDictionary *cfg;
@property(nonatomic, strong) NSDate *lastRiskAlert;
@property(nonatomic, assign) BOOL running, connected, resting, risk;
@property(nonatomic, assign) NSInteger taken, ok, failStreak;   // 连续无数据计数（Ajie consecutivePDPFailures 1:1）
@property(nonatomic, copy) NSString *me, *token, *taskLine;
@property(nonatomic, readonly) dispatch_queue_t q;
- (void)connect:(void (^)(void))after;
- (void)startLoop;
- (void)stopLoop;
- (void)helloTick;
- (void)riskStop;
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
- (void)rememberPdpURL:(NSString *)u;                     // v0.5.24：记 app 真实 pdp/get URL（重放用，90s 内有效）
- (NSString *)freshPdpURL;
- (void)inspectData:(NSData *)data response:(NSURLResponse *)resp
            request:(NSURLRequest *)req error:(NSError *)err;
- (void)inspectJSON:(NSDictionary *)obj;                  // Ajie 同款：NSJSONSerialization 钩子喂进来的对象
- (void)inspectRawBody:(NSString *)body url:(NSString *)u request:(NSURLRequest *)req;
- (NSString *)bodyForShop:(NSString *)shop item:(NSString *)item;
- (void)storeBody:(NSString *)body shop:(NSString *)shop item:(NSString *)item;
- (NSDictionary *)contextCopy;
@end

@implementation AHACapture {
  NSMutableDictionary *_bodies;   // @"shop|item" -> @{ body, at }
  NSMutableDictionary *_ctx;      // app 自己 pdp 请求头快照
  NSString *_pdpURL;              // v0.5.24：app 真实 pdp 请求 URL
  NSDate *_pdpURLAt;
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

// v0.5.24：记 app 真实 pdp 请求 URL（虾皮现在用 /api/v4/pdp/get，get_pc 已是老端点被 SGW 拒）
- (void)rememberPdpURL:(NSString *)u {
  if (u.length == 0) return;
  @synchronized (self) { _pdpURL = [u copy]; _pdpURLAt = [NSDate date]; }
}
- (NSString *)freshPdpURL {
  @synchronized (self) {
    if (!_pdpURL || !_pdpURLAt) return nil;
    if (-[_pdpURLAt timeIntervalSinceNow] > 90) return nil;   // 90 秒内有效，防陈旧任务串号
    return _pdpURL;
  }
}

- (void)inspectData:(NSData *)data response:(NSURLResponse *)resp
            request:(NSURLRequest *)req error:(NSError *)err {
  // v0.5.15 诊断：网络层失败不再静默——get_pc 相关错误打出来，跑一轮就知道
  // 到底是「请求没发出」还是「发出但网络错误」（用户关梯子实验：症状一样，必须区分开）
  NSString *u = req.URL.absoluteString ?: @"";
  BOOL isPc = ([u rangeOfString:kPdpMark].location != NSNotFound);   // v0.5.17=Ajie 1:1：任意 /api/v4/pdp/ 端点，不只 get_pc
  if (err) {
    if (isPc) ahaLog(@"w", [NSString stringWithFormat:@"get_pc 网络错误：%@ (%ld)",
        err.localizedDescription ?: @"未知", (long)err.code]);
    return;
  }
  if (!data.length || !isPc) return;
  NSHTTPURLResponse *hr = [resp isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)resp : nil;
  NSInteger code = hr.statusCode;
  NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  if (!body.length) return;

  // —— 风控识别（Ajie 反汇编 1:1：90309999=验证墙自动停；266900002=按正常响应提交；——
  //     403/418 是 SGW 拒直调重放，不算账号风控。v0.5.15：风控判定放 200 之后，
  //     直调 418 带 90309999 不再把面板打成「已风控」）——
  if (code == 200 && [body containsString:@"90309999"]) {
    ahaLog(@"e", @"PDP返回90309999验证，已暂停");
    if (gPool) dispatch_async(gPool.q, ^{ [gPool riskStop]; });
    ahaRefreshUI();
    return;
  }
  if (code == 403) {
    ahaLog(@"w", @"get_pc 回 HTTP 403（不计入风控）");
    return;
  }
  if (code != 200) {
    ahaLog(@"w", [NSString stringWithFormat:@"get_pc 回 HTTP %ld（请求被 SGW 拒，不计入风控）", (long)code]);
    return;
  }
  if (gPool) { dispatch_async(gPool.q, ^{ gPool.risk = NO; gPool.failStreak = 0; }); }

  // —— 存副本（shop/item：URL query 优先，缺了按 Ajie 同款从 JSON data.item 补；——
  //     266900002 等错误回包照常提交 = Ajie inspectCapturedData 同款）——
  NSURLComponents *uc = [NSURLComponents componentsWithURL:req.URL resolvingAgainstBaseURL:NO];
  NSString *shop = nil, *item = nil;
  for (NSURLQueryItem *qi in uc.queryItems) {
    if ([qi.name isEqualToString:@"shop_id"]) shop = qi.value;
    if ([qi.name isEqualToString:@"item_id"]) item = qi.value;
  }
  if (!shop.length || !item.length) {
    NSData *d = [body dataUsingEncoding:NSUTF8StringEncoding];
    id obj = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    if ([obj isKindOfClass:[NSDictionary class]]) {
      id data = obj[@"data"], it = [data isKindOfClass:[NSDictionary class]] ? data[@"item"] : nil;
      if ([it isKindOfClass:[NSDictionary class]]) {
        if (!item.length) item = [NSString stringWithFormat:@"%@", it[@"item_id"] ?: it[@"itemid"] ?: @""];
        if (!shop.length) shop = [NSString stringWithFormat:@"%@", it[@"shop_id"] ?: it[@"shopid"] ?: @""];
      }
    }
  }
  if (shop.length && item.length && ![shop isEqualToString:@"(null)"] && ![item isEqualToString:@"(null)"])
    [self storeBody:body shop:shop item:item];
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

// —— Ajie inspectCapturedData 的十字段门（0x37c04 逐指令复刻）：
// data.item（或 data.item_data.item）里 models/tier_variations/price/price_min/price_max/
// stock/description/images/item_rating/shop_detailed 至少 8 个非空（汇编 cmp #2 cset hi=最多缺2）。
// 不合格 = 商品页其它 pdp 端点回包/错误回包——交上去聚星受理但下游审核不记完成（今日 80% 完成率的根因）
static BOOL ahaPdpBodyValid(NSString *body) {
  if (body.length < 100) return NO;
  NSData *d = [body dataUsingEncoding:NSUTF8StringEncoding];
  id o = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
  if (![o isKindOfClass:[NSDictionary class]]) return NO;
  id data = o[@"data"];
  if (![data isKindOfClass:[NSDictionary class]]) return NO;
  id item = data[@"item"];
  if (![item isKindOfClass:[NSDictionary class]]) {
    id idd = data[@"item_data"];
    item = [idd isKindOfClass:[NSDictionary class]] ? idd[@"item"] : nil;
    if (![item isKindOfClass:[NSDictionary class]]) return NO;
  }
  static NSArray *fields; static dispatch_once_t onceT;
  dispatch_once(&onceT, ^{
    fields = @[@"models", @"tier_variations", @"price", @"price_min", @"price_max",
               @"stock", @"description", @"images", @"item_rating", @"shop_detailed"];
  });
  NSInteger have = 0;
  for (NSString *f in fields) {
    id v = item[f];
    if (v && ![v isKindOfClass:[NSNull class]]) have++;
  }
  return have >= 8;
}

// 真商品回包但字段不全 → 上限 3 条日志（防刷屏），丢弃不入库
static void ahaBadBodyLog(NSString *body, NSString *shop, NSString *item) {
  static NSInteger sBad = 0;
  if (sBad >= 3) return;
  sBad++;
  ahaLog(@"w", [NSString stringWithFormat:@"PDP回包字段不全，丢弃（%@/%@）", shop, item]);
}

- (NSDictionary *)contextCopy {
  @synchronized (self) { return [_ctx copy]; }
}

// —— Ajie 1:1：get_pc 回包不管走哪种网络栈，最终都要过 NSJSONSerialization 解析——
// 钩子那边把每个解析出的字典喂进来，这里只做形状识别（data.item 带 item_id/shop_id），
// 命中就当作 get_pc 200 回包入库；形状不对立即返回，开销可忽略。
- (void)inspectJSON:(NSDictionary *)obj {
  if (!gPool || ![obj isKindOfClass:[NSDictionary class]]) return;
  @try {
    // v0.5.18 近似命中诊断：窗口内解析到 API 型回包（带 error 键）但形状不符 → 记录顶层键
    if (gObserveUntil && [gObserveUntil compare:[NSDate date]] == NSOrderedAscending &&
        obj[@"error"] != nil) {
      static NSInteger sNearMiss = 0;
      if (sNearMiss < 2) {
        sNearMiss++;
      }
    }
    id data = obj[@"data"];
    if (![data isKindOfClass:[NSDictionary class]]) return;
    id item = data[@"item"];
    if (![item isKindOfClass:[NSDictionary class]]) return;
    ahaStep(@"钩:JSON门");   // v0.5.34 诊断面包屑：真商品回包进门前
    NSString *iid  = [NSString stringWithFormat:@"%@", item[@"item_id"] ?: item[@"itemid"] ?: @""];
    NSString *sid  = [NSString stringWithFormat:@"%@", item[@"shop_id"] ?: item[@"shopid"] ?: @""];
    if (iid.length == 0 || sid.length == 0 || [iid isEqualToString:@"(null)"] || [sid isEqualToString:@"(null)"]) return;

    NSString *body = [[NSString alloc] initWithData:
        [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil] encoding:NSUTF8StringEncoding];
    if (!body.length) return;

    // 风控识别（Ajie 判据：90309999=验证墙；266900002=正常提交）
    if ([body containsString:@"90309999"] || [obj[@"error"] isEqual:@90309999]) {
      ahaLog(@"e", @"PDP返回90309999验证，已暂停（JSON 通道）");
      dispatch_async(gPool.q, ^{ [gPool riskStop]; });
      ahaRefreshUI();
      return;
    }
    dispatch_async(gPool.q, ^{ gPool.risk = NO; });
    dispatch_async(gPool.q, ^{ gPool.risk = NO; gPool.failStreak = 0; });
    if (!ahaPdpBodyValid(body)) { ahaBadBodyLog(body, sid, iid); return; }   // v0.5.31 十字段门
    [self storeBody:body shop:sid item:iid];
  } @catch (__unused NSException *e) { /* 非目标 JSON，静默 */ }
}

// —— Ajie 1:1：delegate 会话的原始字节（didReceiveData 累积 + didComplete 收尾）在这里落库——
// 不管虾皮用什么解析器，原始回包已在手；shop/item 优先从 URL query 取，取不到再按 JSON 形状识别
- (void)inspectRawBody:(NSString *)body url:(NSString *)u request:(NSURLRequest *)req {
  if (!gPool || body.length == 0) return;
  @try {
    // u 为空 = shp 自家回调通道（拿不到 NSURL），交给下面的形状识别把关
    if (u.length && [u rangeOfString:kPdpMark].location == NSNotFound) return;   // v0.5.17：任意 /api/v4/pdp/ 端点
    if (req && req.allHTTPHeaderFields.count) [self rememberContext:req];

    // 风控识别（Ajie 判据；delegate 通道拿不到 HTTP 码，只看回包内容）
    if ([body containsString:@"90309999"]) {
      ahaLog(@"e", @"PDP返回90309999验证，已暂停（delegate 通道）");
      dispatch_async(gPool.q, ^{ [gPool riskStop]; });
      ahaRefreshUI();
      return;
    }

    // shop/item：URL query 优先（mall.shopee.tw 的 get_pc query 里带 item_id/shop_id）
    NSString *shop = nil, *item = nil;
    NSURLComponents *uc = u.length ? [NSURLComponents componentsWithString:u] : nil;
    for (NSURLQueryItem *qi in uc.queryItems ?: @[]) {
      if ([qi.name isEqualToString:@"shop_id"]) shop = qi.value;
      if ([qi.name isEqualToString:@"item_id"]) item = qi.value;
    }
    // query 没有 → 按 JSON 形状识别
    if (!shop.length || !item.length) {
      NSData *d = [body dataUsingEncoding:NSUTF8StringEncoding];
      id obj = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
      if ([obj isKindOfClass:[NSDictionary class]]) {
        id data = obj[@"data"], it = [data isKindOfClass:[NSDictionary class]] ? data[@"item"] : nil;
        if ([it isKindOfClass:[NSDictionary class]]) {
          if (!item.length) item = [NSString stringWithFormat:@"%@", it[@"item_id"] ?: it[@"itemid"] ?: @""];
          if (!shop.length) shop = [NSString stringWithFormat:@"%@", it[@"shop_id"] ?: it[@"shopid"] ?: @""];
        }
      }
    }
    if (u.length && [u rangeOfString:kGetPcMark].location != NSNotFound) ahaStep(@"钩:RAW门");   // v0.5.34 诊断面包屑
    if (![item isKindOfClass:[NSString class]] || item.length == 0 || [item isEqualToString:@"(null)"]) return;
    if (![shop isKindOfClass:[NSString class]] || shop.length == 0 || [shop isEqualToString:@"(null)"]) return;
    dispatch_async(gPool.q, ^{ gPool.risk = NO; gPool.failStreak = 0; });
    if (!ahaPdpBodyValid(body)) { ahaBadBodyLog(body, shop, item); return; }   // v0.5.31 十字段门：query 有参数≠回包合格
    [self storeBody:body shop:shop item:item];
  } @catch (__unused NSException *e) { /* 静默 */ }
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

// （v0.5.13：旧 ahaShopeeNav 已删——回根统一走 ahaPopToRootIfNeeded，Ajie 0x21db0 1:1）

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

// —— 钻取（Ajie resolvedTopViewControllerFromController 0x21ac8 复刻）：
// 弹层逐层解，但 UIAlertController 不钻（Ajie 0x21b58 对一个类做了 isKindOfClass
// 探测后才钻——把弹窗当导航源 VC 传给管理器会静默无效）；导航栈用
// visibleViewController 优先（Ajie 0x63120/0x63128 双选择器序）——
static UIViewController *ahaDrillFrom(UIViewController *vc) {
  if (!vc) return nil;
  while (vc.presentedViewController &&
         ![vc.presentedViewController isKindOfClass:[UIAlertController class]])
    vc = vc.presentedViewController;
  if ([vc isKindOfClass:[UITabBarController class]])
    vc = [(UITabBarController *)vc selectedViewController] ?: vc;
  if ([vc isKindOfClass:[UINavigationController class]])
    vc = [(UINavigationController *)vc visibleViewController]
         ?: [(UINavigationController *)vc topViewController] ?: vc;
  while (vc.presentedViewController &&
         ![vc.presentedViewController isKindOfClass:[UIAlertController class]])
    vc = vc.presentedViewController;
  return vc;
}

static UIViewController *ahaResolvedTopVC(void) {
  UIWindow *own = ahaOwnWin();
  UIWindow *main = nil;
  for (UIWindow *w in [UIApplication sharedApplication].windows) {
    if (w == own || w.hidden || !w.rootViewController || w.alpha < 0.1) continue;
    if (!main || w.isKeyWindow) main = w;
    if (w.isKeyWindow) break;
  }
  if (!main) return nil;
  return ahaDrillFrom(main.rootViewController);
}

// —— Ajie routeBackOnce 复刻：manager 级回退（它 dylib 里的 8 个回退选择器，goBack 优先）——
// Shopee 的页面栈不一定是纯 UINavigationController，manager 级回退才是它原生认的「返回」
static void ahaRouteBackOnce(void) {
  id nav = ahaResolveManager();
  if (!nav) return;
  for (NSString *m in @[@"goBack", @"navigateBack", @"back", @"popViewController",
                        @"pop", @"goBackAnimated:", @"navigateBackAnimated:", @"popViewControllerAnimated:"]) {
    SEL s = NSSelectorFromString(m);
    if (![nav respondsToSelector:s]) continue;
    // 带参的回退选择器（Animated: 系列）补一个 NO，避免裸调吃到垃圾参数
    NSArray *args = [m hasSuffix:@":"] ? @[@NO] : @[];
    if (ahaInvoke(nav, s, args, @"routeBack")) return;
  }
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
// 4 种 route 格式轮试 × navigate/push 双候选。注意：invoke「不抛异常」≠ 页面真的跳了
//（Ajie 的成功判定也是这样），所以调用层只负责「调了没有」，页面验证在外层做 ——
static BOOL ahaTryRouteInvokes(NSArray *routes) {
  ahaStep(@"导航:解析管理器");
  id nav = ahaResolveManager();
  if (!nav) { ahaLog(@"w", @"跳转失败:无导航器"); return NO; }

  // topVC 只取一次（Ajie navigateWithBTManagerToRoute 0x24028 同款：主入口取好往下传）
  UIViewController *vc = ahaResolvedTopVC();
  if (!vc) { ahaLog(@"w", @"跳转失败:无控制器"); return NO; }

  SEL navSel  = NSSelectorFromString(@"navigateFromViewController:destinationPath:navigateOption:completion:");
  SEL pushSel = NSSelectorFromString(@"pushFromViewController:destinationPath:pushOption:completion:");

  NSUInteger idx = 0;
  for (NSString *route in routes) {
    ahaStep(@"导航:造路径对象");
    id path = nil;
    @try { path = ahaBuildPath(route); } @catch (__unused NSException *e) { path = nil; }
    if (!path) { idx++; continue; }
    if ([nav respondsToSelector:navSel]) {
      ahaStep(@"导航:navigate 调用");
      if (ahaInvoke(nav, navSel, @[vc, path, [NSNull null], [NSNull null]], @"navigate")) {
        return YES;   // v0.5.28 精简：命中不再刷日志
      }
    }
    if ([nav respondsToSelector:pushSel]) {
      ahaStep(@"导航:push 调用");
      if (ahaInvoke(nav, pushSel, @[vc, path, [NSNull null], [NSNull null]], @"push")) {
        return YES;
      }
    }
    idx++;
  }
  return NO;
}

// —— Ajie 兜底级（invokeRouteNavigationOnManager 0x23a44~0x23df0 实证）：
//    manager 自带的商品直开方法，不需要路径对象，参数 [shopID, itemID]（nil→@""）——
static BOOL ahaTryDirectOpens(NSString *shopId, NSString *itemId) {
  id nav = ahaResolveManager();
  if (!nav) return NO;
  NSString *shop = shopId ?: @"", *item = itemId ?: @"";
  for (NSString *m in @[@"navigateToProduct:goodID:", @"openProductPage:goodID:", @"openProduct:goodID:"]) {
    SEL s = NSSelectorFromString(m);
    if (![nav respondsToSelector:s]) continue;
    ahaStep(@"导航:商品直开");
    if (ahaInvoke(nav, s, @[shop, item], m)) return YES;
  }
  return NO;
}

// —— Ajie popToRootViewControllerIfNeeded 0x21db0 逐指令复刻：
// mainWindow root → resolvedTop 钻取 → 是 TabBar 就取 selectedVC → 拿 navigationController
// → 栈深>1 才 popToRootViewControllerAnimated:（不是我们自己猜的 count>2 + routeBackOnce）——
static void ahaPopToRootIfNeeded(void) {
  UIWindow *own = ahaOwnWin();
  UIWindow *main = nil;
  for (UIWindow *w in [UIApplication sharedApplication].windows) {
    if (w == own || !w.rootViewController) continue;
    if (!main || w.isKeyWindow) main = w;
    if (w.isKeyWindow) break;
  }
  if (!main) return;
  UIViewController *vc = ahaDrillFrom(main.rootViewController);
  UINavigationController *nc = [vc isKindOfClass:[UINavigationController class]]
      ? (UINavigationController *)vc : vc.navigationController;
  if (nc && nc.viewControllers.count > 1) {
    ahaStep(@"导航:回根");
    [nc popToRootViewControllerAnimated:NO];
  }
}

// —— Ajie openCurrentTask 的 Universal Link 兜底 0x2fe2c~0x300d0 逐指令复刻：
// 内路由失败后 openURL 打商品链接（UniversalLinksOnly 强制走 app 内跳转）。
// v0.5.27 用户指令：删掉「回退链接跳转」（普通 openURL 会弹 Safari 往网页跳）——
// app 没接这个域时宁可跳转失败任务回池，绝不弹网页。
static void ahaOpenUniversalLink(NSString *shopId, NSString *itemId, NSString *taskUrl) {
  NSString *u = taskUrl ?: @"";
  if (u.length == 0 || ![u hasPrefix:@"http"])
    u = [NSString stringWithFormat:@"https://shopee.tw/product/%@/%@", shopId ?: @"", itemId ?: @""];
  NSURL *url = [NSURL URLWithString:u];
  if (!url) { ahaLog(@"w", @"跳转失败:无URL"); return; }
  [[UIApplication sharedApplication] openURL:url
    options:@{ UIApplicationOpenURLOptionUniversalLinksOnly: @YES }
    completionHandler:^(BOOL ok) {
      ahaLog(ok ? @"i" : @"w", ok ? @"进入详情成功" : @"进入详情重试（不弹网页）");
    }];
}

#pragma mark - 观察钩子（Ajie 同款：包 completionHandler，不碰 protocolClasses）

%group gNetCapture
%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
    completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))handler {
  NSString *u = request.URL.absoluteString ?: @"";
  ahaObserveURL([@"H:" stringByAppendingString:u]);   // v0.5.20：H=completionHandler 通道
  BOOL isPdp = ([u rangeOfString:kPdpMark].location != NSNotFound);
  if (isPdp) {
    [[AHACapture shared] rememberContext:request];
    [[AHACapture shared] rememberPdpURL:u];   // v0.5.24：app 真实 pdp/get URL，超时后重放用它
  }
  if (!isPdp || !handler) return %orig;
  NSURLRequest *reqCopy = [request copy];
  return %orig(request, ^(NSData *d, NSURLResponse *r, NSError *e) {
    ahaObserveRecv();
    [[AHACapture shared] inspectData:d response:r request:reqCopy error:e];
    handler(d, r, e);
  });
}
- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)URL
    completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))handler {
  NSString *u = URL.absoluteString ?: @"";
  ahaObserveURL([@"H:" stringByAppendingString:u]);   // v0.5.20：H=completionHandler 通道
  BOOL isPdp = ([u rangeOfString:kPdpMark].location != NSNotFound);
  if (isPdp) {
    NSURLRequest *req = [NSURLRequest requestWithURL:URL];
    [[AHACapture shared] rememberContext:req];
    [[AHACapture shared] rememberPdpURL:u];   // v0.5.24
    return %orig(URL, ^(NSData *d, NSURLResponse *r, NSError *e) {
      ahaObserveRecv();
      [[AHACapture shared] inspectData:d response:r request:req error:e];
      if (handler) handler(d, r, e);
    });
  }
  return %orig;
}
%end
%end // gNetCapture
// v0.5.23：删掉两个无 completionHandler 观察钩（dataTaskWithRequest:/dataTaskWithURL:）——
// Ajie 反汇编实证装钩面只有 3 个钩（0x1423c/0x1425c/0x14290），我们多钩的这两个是
// 唯一的钩子面差异，一并削除，钩子面与 Ajie 完全等价

%group gNetJSON
// —— Ajie 1:1 第三钩：NSJSONSerialization（万能兜底）——
// 虾皮任何网络栈（delegate 式会话/自研封装）拿到回包后都要用系统 JSON 解析器，
// 在这里按形状识别 get_pc 回包，delegate 会话也能抓到（Ajie 实证做法）
%hook NSJSONSerialization
+ (id)JSONObjectWithData:(NSData *)data options:(NSUInteger)opts error:(NSError **)error {
  id obj = %orig;
  if (gObserveUntil && [gObserveUntil compare:[NSDate date]] == NSOrderedAscending) gObsJSON++; // v0.5.18
  if ([obj isKindOfClass:[NSDictionary class]]) {
    @try { [[AHACapture shared] inspectJSON:obj]; } @catch (__unused NSException *e) { /* 非目标 */ }
  }
  return obj;
}
%end
%end // gNetJSON

#pragma mark - Ajie 1:1 第四钩（v0.5.12 = 反汇编逐字对齐版）

// Ajie 0.1.3 实证结构（装钩 0x41d7c + 钩体 0x42e28/0x43048 + helper 0x43528）：
//   1) 钩 +[NSURLSession sessionWithConfiguration:delegate:delegateQueue:]（元类），从 delegate 拿类；
//   2) 选择器优先虾皮自家回调 shpNetworkingModule:shpRequest:didReceiveData:/didCompleteWithError:，
//      delegate 不响应才回退 URLSession:dataTask:didReceiveData: / URLSession:task:didCompleteWithError:；
//   3) orig IMP 按类名存两个全局字典（Ajie: BSS 0x63ef0/0x63ef8，NSValue valueWithPointer）——
//      【v0.5.11 血坑】绝不能放全局槽位：多个 delegate 类会互相覆盖 orig，
//      A 类回调调到 B 类的 IMP = 堆损坏 → 启动 2 秒后在无关系统代码里随机崩；
//   4) 钩体先调 orig 再自己处理（Ajie 同序）；
//   5) 累积字节优先 piggyback 在 request-like 对象上（Ajie 用 keyed subscript），
//      URLSession task 挂不上就用 gTaskBuf 表兜底。

static NSMutableDictionary *gOrigDataDict = nil;   // 类名 → orig(didReceiveData 系)
static NSMutableDictionary *gOrigDoneDict = nil;   // 类名 → orig(didComplete 系)
static NSMutableDictionary *gTaskBuf = nil;        // 兜底累积表：task 指针串 → 字节
static NSString *const kAhaBufKey = @"aha_buf_v1"; // piggyback 键

static IMP ahaOrigFor(NSMutableDictionary *dict, id obj) {
  if (!dict || !obj) return NULL;
  Class cls = object_getClass(obj);
  if (!cls) return NULL;
  NSString *cn = NSStringFromClass(cls);
  if (cn.length == 0) return NULL;
  NSValue *v = nil;
  @synchronized (dict) { v = dict[cn]; }
  return v ? (IMP)v.pointerValue : NULL;
}

static void ahaDelegateDidReceiveData(id self, SEL _cmd, id module, id requestLike, NSData *data);
static void ahaDelegateDidComplete(id self, SEL _cmd, id module, id requestLike, NSError *error);

static void ahaSwizzleDelegate(id delegate) {
  if (!delegate) return;
  @try {
    Class cls = object_getClass(delegate);
    if (!cls) return;
    if (!gOrigDataDict) gOrigDataDict = [NSMutableDictionary dictionary];
    if (!gOrigDoneDict) gOrigDoneDict = [NSMutableDictionary dictionary];
    if (!gTaskBuf)      gTaskBuf      = [NSMutableDictionary dictionary];
    NSString *cn = NSStringFromClass(cls);
    if (cn.length == 0) return;
    BOOL already = NO;
    @synchronized (gOrigDataDict) { already = (gOrigDataDict[cn] != nil); }
    @synchronized (gOrigDoneDict) { already = already || (gOrigDoneDict[cn] != nil); }
    if (already) return;

    // v0.5.23 恢复挂钩（v0.5.21 曾全停）：Ajie 同款做法实证无罪——
    // Ajie 也对 delegate 类做 MSHookMessageEx（shp 回调优先）且同引擎同类名，照样活着。
    // delegate 钩是 Ajie 的主采集通道（shp 自家回调），恢复=与 Ajie 完全等价
    SEL selShpData = sel_registerName("shpNetworkingModule:shpRequest:didReceiveData:");
    SEL selShpDone = sel_registerName("shpNetworkingModule:shpRequest:didCompleteWithError:");
    BOOL shpWay = [delegate respondsToSelector:selShpData];
    SEL selData = shpWay ? selShpData : NSSelectorFromString(@"URLSession:dataTask:didReceiveData:");
    SEL selDone = [delegate respondsToSelector:selShpDone] ? selShpDone
                  : NSSelectorFromString(@"URLSession:task:didCompleteWithError:");

    IMP origData = NULL, origDone = NULL;
    if ([delegate respondsToSelector:selData]) {
      MSHookMessageEx(cls, selData, (IMP)ahaDelegateDidReceiveData, &origData);
      if (origData) @synchronized (gOrigDataDict) { gOrigDataDict[cn] = [NSValue valueWithPointer:origData]; }
    }
    if ([delegate respondsToSelector:selDone]) {
      MSHookMessageEx(cls, selDone, (IMP)ahaDelegateDidComplete, &origDone);
      if (origDone) @synchronized (gOrigDoneDict) { gOrigDoneDict[cn] = [NSValue valueWithPointer:origDone]; }
    }

    // v0.5.28 精简：装钩登记不再刷日志（cn/way 仅留作登记标记）
    static NSInteger sSwizzleLog = 0;
    sSwizzleLog += shpWay ? 1 : 0;
    (void)sSwizzleLog;
  } @catch (__unused NSException *e) { /* 静默 */ }
}

static void ahaDelegateDidReceiveData(id self, SEL _cmd, id module, id requestLike, NSData *data) {
  ahaObserveRecv();   // v0.5.19：回包事件计数（delegate 通道）
  IMP orig = ahaOrigFor(gOrigDataDict, self);
  if (orig)
    ((void (*)(id, SEL, id, id, NSData *))orig)(self, _cmd, module, requestLike, data); // Ajie 同序：先过 orig
  @try {
    if (!requestLike || !data.length) return;
    if ([requestLike isKindOfClass:[NSURLSessionTask class]]) {
      // URLSession 路径：pdp 请求头快照（原无 completionHandler 钩子的职责，Ajie 也在这里记上下文）
      NSURLSessionTask *task = (NSURLSessionTask *)requestLike;
      NSURLRequest *req = task.currentRequest;
      if (req) {
        ahaObserveURL(req.URL.absoluteString);            // v0.5.16：delegate 会话的请求也进观察窗
        if ([req.URL.absoluteString rangeOfString:kPdpMark].location != NSNotFound) {
          [[AHACapture shared] rememberPdpURL:req.URL.absoluteString];   // v0.5.24
          if (req.allHTTPHeaderFields.count)
            [[AHACapture shared] rememberContext:req];
        }
      }
      // 累积字节走兜底表
      NSString *key = [NSString stringWithFormat:@"%p", task];
      @synchronized (gTaskBuf) {
        NSMutableData *buf = gTaskBuf[key];
        if (!buf) { buf = [NSMutableData data]; gTaskBuf[key] = buf; }
        if (buf.length + data.length > 2 * 1024 * 1024) {   // 单任务 2MB 封顶
          [gTaskBuf removeObjectForKey:key];
        } else {
          [buf appendData:data];
        }
        if (gTaskBuf.count > 128) {                         // 任务表防膨胀
          NSString *first = gTaskBuf.allKeys.firstObject;
          if (first) [gTaskBuf removeObjectForKey:first];
        }
      }
    } else if ([requestLike respondsToSelector:NSSelectorFromString(@"data")]) {
      // Ajie 1:1（0x42e28 实证）：shp 请求对象自带 data 属性 → 直接 appendData 累积
      SEL selData = NSSelectorFromString(@"data");
      NSMutableData *buf = ((id (*)(id, SEL))objc_msgSend)(requestLike, selData);
      if (![buf isKindOfClass:[NSMutableData class]]) {
        SEL selSetData = NSSelectorFromString(@"setData:");
        if ([requestLike respondsToSelector:selSetData]) {
          buf = [NSMutableData data];
          ((void (*)(id, SEL, id))objc_msgSend)(requestLike, selSetData, buf);
        }
      }
      if ([buf isKindOfClass:[NSMutableData class]]) {
        [buf appendData:data];
      } else if ([requestLike respondsToSelector:@selector(objectForKeyedSubscript:)] &&
                 [requestLike respondsToSelector:@selector(setObject:forKeyedSubscript:)]) {
        NSMutableData *buf2 = [requestLike objectForKeyedSubscript:kAhaBufKey];
        if (![buf2 isKindOfClass:[NSMutableData class]]) {
          buf2 = [NSMutableData data];
          [requestLike setObject:buf2 forKeyedSubscript:kAhaBufKey];
        }
        [buf2 appendData:data];
      }
    } else if ([requestLike respondsToSelector:@selector(objectForKeyedSubscript:)] &&
               [requestLike respondsToSelector:@selector(setObject:forKeyedSubscript:)]) {
      // Ajie 同款：shp 请求对象是字典式的，累积字节直接挂它身上
      NSMutableData *buf = [requestLike objectForKeyedSubscript:kAhaBufKey];
      if (![buf isKindOfClass:[NSMutableData class]]) {
        buf = [NSMutableData data];
        [requestLike setObject:buf forKeyedSubscript:kAhaBufKey];
      }
      [buf appendData:data];
    }
  } @catch (__unused NSException *e) { /* 静默 */ }
}

static void ahaDelegateDidComplete(id self, SEL _cmd, id module, id requestLike, NSError *error) {
  IMP orig = ahaOrigFor(gOrigDoneDict, self);
  if (orig)
    ((void (*)(id, SEL, id, id, NSError *))orig)(self, _cmd, module, requestLike, error); // Ajie 同序
  @try {
    if (error) {
      // v0.5.18：任何 delegate 任务的失败都记（前 5 条封顶）——
      // 页面「載入失敗」必有对应错误在这里浮出，除非请求根本没经过我们钩住的通道
      static NSInteger sErrLog = 0;
      if (sErrLog < 5) {
        sErrLog++;
        NSString *u = @"";
        if ([requestLike isKindOfClass:[NSURLSessionTask class]])
          u = ((NSURLSessionTask *)requestLike).currentRequest.URL.absoluteString ?: @"";
        if (u.length > 90) u = [[u substringToIndex:90] stringByAppendingString:@"…"];
        ahaLog(@"w", [NSString stringWithFormat:@"delegate回包错误(%ld): %@ %@",
               (long)error.code, error.localizedDescription ?: @"", u]);
      }
      return;
    }
    if (!gPool) return;
    NSData *bufData = nil;
    BOOL isTask = [requestLike isKindOfClass:[NSURLSessionTask class]];
    // v0.5.17 = Ajie 1:1（0x431d4 实证）：按 responseData/data/rawData/bodyData 四键读累积，
    // 外加我们自己的 piggyback 键；再试 data 属性（didReceiveData 的 Ajie 同款累积位）
    if ([requestLike respondsToSelector:@selector(objectForKeyedSubscript:)]) {
      SEL selRemove = NSSelectorFromString(@"removeObjectForKeyedSubscript:");
      for (NSString *k in @[@"responseData", @"data", @"rawData", @"bodyData", kAhaBufKey]) {
        id pig = [requestLike objectForKeyedSubscript:k];
        if ([pig isKindOfClass:[NSData class]] && [(NSData *)pig length] > 0) {
          bufData = [NSData dataWithData:pig];
          if ([k isEqualToString:kAhaBufKey] && [requestLike respondsToSelector:selRemove])
            ((void (*)(id, SEL, id))objc_msgSend)(requestLike, selRemove, kAhaBufKey); // 取完即清，防重复投递
          break;
        }
      }
    }
    if (!bufData) {
      SEL selData = NSSelectorFromString(@"data");
      if (!isTask && [requestLike respondsToSelector:selData]) {
        id buf = ((id (*)(id, SEL))objc_msgSend)(requestLike, selData);
        if ([buf isKindOfClass:[NSData class]] && [(NSData *)buf length] > 0) bufData = [NSData dataWithData:buf];
      }
    }
    if (!bufData && isTask) {
      NSString *key = [NSString stringWithFormat:@"%p", requestLike];
      @synchronized (gTaskBuf) {
        NSMutableData *buf = gTaskBuf[key];
        bufData = buf ? [NSData dataWithData:buf] : nil;
        [gTaskBuf removeObjectForKey:key];
      }
    }
    if (bufData.length == 0) return;
    // v0.5.28 精简：shp 通道存活探针日志移除
    NSString *u = @"";
    NSURLRequest *req = nil;
    if (isTask) {
      req = ((NSURLSessionTask *)requestLike).currentRequest;
      u = req.URL.absoluteString ?: @"";
    } else {
      // v0.5.17 = Ajie sub_0xa3e4 同款：从 shp 请求对象提取 URL（.URL / .request.URL）
      SEL selURL = NSSelectorFromString(@"URL");
      id urlObj = nil;
      if ([requestLike respondsToSelector:selURL])
        urlObj = ((id (*)(id, SEL))objc_msgSend)(requestLike, selURL);
      if (![urlObj isKindOfClass:[NSURL class]]) {
        SEL selReq = NSSelectorFromString(@"request");
        if ([requestLike respondsToSelector:selReq]) {
          id rq = ((id (*)(id, SEL))objc_msgSend)(requestLike, selReq);
          if ([rq respondsToSelector:selURL]) urlObj = ((id (*)(id, SEL))objc_msgSend)(rq, selURL);
        }
      }
      if ([urlObj isKindOfClass:[NSURL class]]) u = [(NSURL *)urlObj absoluteString] ?: @"";
    }
    // URL 已知且不是 pdp 端点 → 跳过；URL 未知（空串）→ inspectRawBody 只靠形状识别把关
    if (u.length && [u rangeOfString:kPdpMark].location == NSNotFound) return;
    NSString *body = [[NSString alloc] initWithData:bufData encoding:NSUTF8StringEncoding];
    [[AHACapture shared] inspectRawBody:body url:u request:req];
  } @catch (__unused NSException *e) { /* 静默 */ }
}

%group gNetSession
%hook NSURLSession
+ (NSURLSession *)sessionWithConfiguration:(NSURLSessionConfiguration *)configuration
    delegate:(id)delegate delegateQueue:(NSOperationQueue *)queue {
  NSURLSession *s = %orig;
  ahaSwizzleDelegate(delegate);   // 虾皮每建一个 session 就把它的 delegate 挂上钩
  return s;
}
%end
%end // gNetSession

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
  if (self.risk) return @"● 此账号已风控！";
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
  // Ajie 风格：纯文本消息，时间用 [] 框住（用户指定）；不再用 ✔✖⚠ 前缀
  static NSDateFormatter *df; static dispatch_once_t dOnce;
  dispatch_once(&dOnce, ^{
    df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"HH:mm:ss";
  });
  NSString *line = [NSString stringWithFormat:@"[%@] %@", [df stringFromDate:[NSDate date]], msg ?: @""];
  if (line.length > 160) line = [[line substringToIndex:160] stringByAppendingString:@"…"];
  @synchronized (_logs) {
    [_logs addObject:line];
    if (_logs.count > 120) [_logs removeObjectsInRange:NSMakeRange(0, _logs.count - 120)];   // v0.5.28 精简：120 行
  }
  ahaRefreshUI();
}

static void ahaLog(NSString *lv, NSString *msg) {
  if (gPool) [gPool appendLog:(lv ?: @"i") msg:(msg ?: @"")];
}

// —— 风控自动停（Ajie handleRiskControlDetectedWithMessage 反汇编 1:1）：
// isRiskControlled=YES + 停循环 + 清在途标志。Ajie 全程无弹窗，只留日志与状态行 ——
- (void)riskStop {
  self.risk = YES;
  if (!self.running) return;
  self.running = NO;
  self.resting = NO;
  self.taskLine = @"";
  ahaRefreshUI();
  [self helloTick];   // v0.5.33 立即上报风控阶段（不等 10s 心跳）
}

// —— 连续无数据（Ajie handleNoDataCapture 1:1）：
// 直连失败不计入；连续 2 次 → 「疑似触发风控或验证码」+ 自动暂停 ——
- (void)noteCaptureFailure:(BOOL)directOnly {
  if (directOnly) {
    ahaLog(@"w", @"直连失败，不计入风控");
    return;
  }
  self.failStreak++;
  if (self.failStreak < 2) {
    ahaLog(@"w", [NSString stringWithFormat:@"没等到商品数据（连续 %ld 次）", (long)self.failStreak]);
    return;
  }
  ahaLog(@"e", @"连续两次未获取到数据，疑似触发风控或验证码，请手动查看，已自动暂停");
  [self riskStop];
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
    // v0.5.24：default→ephemeral（cookie/缓存隔离，绝不污染 app 的共享存储）
    sess = AhaSession([NSURLSessionConfiguration ephemeralSessionConfiguration]);
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

// —— 心跳（10s，常驻；v0.5.33 起带 phase 上报设备状态）——
// 中枢 BAD_WIN_PHASES：slider/risk/net/login/stopped（坏阶段剔除出有效窗口，不为它配货）；
// 正常阶段：ok/take/nav/wait/submit/gap。设备状态映射：
//   risk=风控自动停  login=未连接/掉登  stopped=循环已停  gap=休息中  ok=跑单中
- (void)helloTick {
  NSString *pid = [self.cfg[@"pid"] stringByTrimmingCharactersInSet:
      [NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
  if (pid.length == 0 || self.base.length == 0) return;
  NSString *ph = @"ok";
  if (self.risk) ph = @"risk";
  else if (!self.token) ph = @"login";
  else if (!self.running) ph = @"stopped";
  else if (self.resting) ph = @"gap";
  [self api:@"/api/pool/hello" method:@"POST"
      body:@{ @"profileId": pid, @"phase": ph } done:nil];
}

// —— 开始 / 停止 ——
- (void)startLoop {
  if (gPure) { ahaLog(@"w", @"当前是纯净模式（无采集钩子），请先到设置⚙切到完整模式并重启虾皮"); ahaRefreshUI(); return; }
  if (!self.connected) { [self connect:^{ [self beginRun]; }]; return; }
  [self beginRun];
}
- (void)beginRun {
  dispatch_async(self.q, ^{
    if (self.running) return;
    self.running = YES; self.resting = NO; self.risk = NO; self.failStreak = 0;
    ahaLog(@"s", @"领单循环已开始");
    ahaRefreshUI();
    [self helloTick];   // v0.5.33 立即恢复有效窗口（不等 10s 心跳）
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
    [self helloTick];   // v0.5.33 立即上报 stopped 阶段
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

// —— 优惠券检测（验券，Ajie 0x187d8~0x1ad68 逐函数 1:1）——
// 服务：http://103.146.231.72:1998（Ajie 同款验券服务+固定 token，用户在设置里填「后端用户ID」开启）
// start : POST /api/coupon-preflight/start/  {shopeeUserId, shopeeUsername, force}
//         resp {allowed, required, dayKey, probe:{id,url,shopId,itemId}}
//         allowed 且 !required → 直接过；required → 探测 probe.url（GET+重放 app 上下文，get_pc 同款）→ report
// report: POST /api/coupon-preflight/report/  {probeId, accountId, status:'captured', rawResponseText, reason}
//         resp {passed, reason}
- (void)couponRequest:(NSString *)path body:(NSDictionary *)body
               done:(void (^)(NSDictionary *, NSError *))done {
  NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
      [NSURL URLWithString:[@"http://103.146.231.72:1998" stringByAppendingString:path]]];
  req.HTTPMethod = @"POST";
  req.timeoutInterval = 20;
  [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
  // Ajie sendCouponRequest 实锤：固定 Bearer token（0x188cc）
  [req setValue:@"Bearer -CN6_PNYhHpDzN-qJw-RGecT5vOM1nY8zqORenKnFnw"
      forHTTPHeaderField:@"Authorization"];
  if (body) req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
  static NSURLSession *sess = nil; static dispatch_once_t once;
  dispatch_once(&once, ^{
    sess = AhaSession([NSURLSessionConfiguration ephemeralSessionConfiguration]);
  });
  [[sess dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
    NSDictionary *j = nil;
    if (!e && d) j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    done(j, e);
  }] resume];
}

- (NSString *)couponTodayKey {
  static NSDateFormatter *df; static dispatch_once_t once;
  dispatch_once(&once, ^{
    df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"yyyyMMdd";
    df.timeZone = [NSTimeZone timeZoneWithName:@"Asia/Taipei"];
  });
  return [df stringFromDate:[NSDate date]];
}

// 领单前的验券闸门（Ajie takeTaskAfterCouponPreflight 1:1）：ok=YES 才继续领单
- (void)couponPreflightThen:(void (^)(BOOL ok))next {
  NSString *acct = [self.cfg[@"couponAcct"] stringByTrimmingCharactersInSet:
      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if (acct.length == 0) { next(YES); return; }              // 没填账号 = 不启用
  // 今日已检测过 → 直接放行（Ajie couponPassedUserId/couponPassedDayKey 缓存同款）
  if ([self.cfg[@"couponPassedUserId"] isEqualToString:acct] &&
      [self.cfg[@"couponPassedDayKey"] isEqualToString:[self couponTodayKey]]) {
    ahaLog(@"i", @"优惠券预检通过（今日已检测）");
    next(YES); return;
  }
  ahaLog(@"i", @"优惠券预检中...");
  [self couponRequest:@"/api/coupon-preflight/start/"
      body:@{ @"shopeeUserId": acct, @"shopeeUsername": self.cfg[@"user"] ?: @"", @"force": @NO }
      done:^(NSDictionary *j, NSError *e) {
    dispatch_async(self.q, ^{
      if (e || ![j isKindOfClass:[NSDictionary class]]) {
        ahaLog(@"e", [NSString stringWithFormat:@"优惠券预检失败:%@", e.localizedDescription ?: @"响应异常"]);
        next(NO); return;
      }
      BOOL allowed  = [j[@"allowed"] boolValue];
      BOOL required = [j[@"required"] boolValue];
      if (allowed && !required) {
        self.cfg[@"couponPassedUserId"] = acct;
        self.cfg[@"couponPassedDayKey"] = [NSString stringWithFormat:@"%@", j[@"dayKey"] ?: [self couponTodayKey]];
        [self saveCfg];
        ahaLog(@"i", @"优惠券预检通过（今日已检测）");
        next(YES); return;
      }
      NSDictionary *probe = j[@"probe"];
      if (!required || ![probe isKindOfClass:[NSDictionary class]] ||
          [NSString stringWithFormat:@"%@", probe[@"url"] ?: @""].length == 0) {
        ahaLog(@"e", @"优惠券预检失败: 服务端未下发探测任务");
        next(NO); return;
      }
      // 探测：GET probe.url（get_pc 同款形态），重放 app 上下文头（directFetch 复用）
      NSString *pUrl  = [NSString stringWithFormat:@"%@", probe[@"url"] ?: @""];
      NSString *pShop = [NSString stringWithFormat:@"%@", probe[@"shopId"] ?: @""];
      NSString *pItem = [NSString stringWithFormat:@"%@", probe[@"itemId"] ?: @""];
      ahaLog(@"i", @"开始优惠券数据检测...");
      NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:pUrl]];
      req.HTTPMethod = @"GET"; req.timeoutInterval = 20;
      NSDictionary *ctx = [[AHACapture shared] contextCopy];
      for (NSString *k in ctx) {
        if ([k caseInsensitiveCompare:@"Content-Length"] == NSOrderedSame) continue;
        [req setValue:ctx[k] forHTTPHeaderField:k];
      }
      __block NSString *pBody = nil;
      dispatch_semaphore_t sem = dispatch_semaphore_create(0);
      [[AhaSession([NSURLSessionConfiguration ephemeralSessionConfiguration])
        dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *err) {
        NSHTTPURLResponse *hr = [r isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)r : nil;
        if (!err && d && hr.statusCode == 200)
          pBody = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
        else
          ahaLog(@"w", [NSString stringWithFormat:@"优惠券检测获取数据失败:HTTP=%ld", (long)hr.statusCode]);
        dispatch_semaphore_signal(sem);
      }] resume];
      dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(22 * NSEC_PER_SEC)));
      if (pBody.length == 0) { next(NO); return; }
      ahaLog(@"i", @"优惠券检测数据已采集，上报中...");
      [self couponRequest:@"/api/coupon-preflight/report/"
          body:@{ @"probeId":  [NSString stringWithFormat:@"%@", probe[@"id"] ?: @""],
                  @"accountId": acct,
                  @"status": @"captured",
                  @"rawResponseText": pBody,
                  @"reason": [NSString stringWithFormat:@"item-%@ shop-%@", pItem, pShop] }
          done:^(NSDictionary *rj, NSError *re) {
        dispatch_async(self.q, ^{
          BOOL passed = [rj isKindOfClass:[NSDictionary class]] && [rj[@"passed"] boolValue];
          if (passed) {
            self.cfg[@"couponPassedUserId"] = acct;
            self.cfg[@"couponPassedDayKey"] = [self couponTodayKey];
            [self saveCfg];
            ahaLog(@"s", @"优惠券检测通过");
            next(YES);
          } else {
            ahaLog(@"e", [NSString stringWithFormat:@"优惠券检测未通过:%@",
                (rj[@"reason"] ?: (re.localizedDescription ?: @"数据异常"))]);
            next(NO);
          }
        });
      }];
    });
  }];
}

- (void)takeOnce {
  dispatch_async(self.q, ^{
    if (!self.running || !self.token) { ahaRefreshUI(); return; }
    // 验券闸门（Ajie takeTaskAfterCouponPreflight 1:1）：设置里填了「后端用户ID」才启用
    if ([self.cfg[@"couponAcct"] length] > 0) {
      [self couponPreflightThen:^(BOOL ok) {
        dispatch_async(self.q, ^{
          if (ok) { [self takeOnceGo]; }
          else {
            self.taskLine = @"";
            ahaRefreshUI();
            [self scheduleNext:MAX([self randomGap], 30)];   // 未通过歇一会再试
          }
        });
      }];
      return;
    }
    [self takeOnceGo];
  });
}

- (void)takeOnceGo {
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
          ahaLog(@"e", [NSString stringWithFormat:@"抢单失败：%@", e.localizedDescription]);
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
          ahaRefreshUI();
          // v0.5.29：每一轮的状态都要显示（用户要求，Ajie 同款每步留痕）
          ahaLog(@"i", [NSString stringWithFormat:@"无单，%.0f秒后再抢", wait]);
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
  // 双保险：老版本 hub 入库的任务可能缺 shop/item——taskUrl 里一定有（-i.SHOP.ITEM 或 /product/SHOP/ITEM）
  if (itemId.length == 0 || shopId.length == 0) {
    static NSRegularExpression *re; static dispatch_once_t onceT;
    dispatch_once(&onceT, ^{
      re = [NSRegularExpression regularExpressionWithPattern:
            @"/product/(\\d+)/(\\d+)|-i\\.(\\d+)\\.(\\d+)" options:0 error:nil];
    });
    if (re && taskUrl.length) {
      NSTextCheckingResult *m = [re firstMatchInString:taskUrl options:0 range:NSMakeRange(0, taskUrl.length)];
      if (m) {
        NSString * (^g)(NSInteger) = ^NSString *(NSInteger i) {
          NSRange r = [m rangeAtIndex:i];
          return (r.location != NSNotFound) ? [taskUrl substringWithRange:r] : @"";
        };
        if (shopId.length == 0) shopId = g(1).length ? g(1) : g(3);
        if (itemId.length == 0) itemId = g(2).length ? g(2) : g(4);
        if (shopId.length && itemId.length) { /* v0.5.30：补解析不再刷日志 */ }
      }
    }
  }
  self.taskLine = [NSString stringWithFormat:@"#%@ [%@] item %@ · 打开商品页", taskId, acct, itemId];
  // v0.5.26 提交 url 必须与 PC 中控台 collectBuildPcUrl 插件同款构造规则一致：
  // get_pc 接口 URL（聚星按这个格式收单）；此前直交 taskUrl（product/ 商品页）= 偏离同款
  NSString *pcUrl = [NSString stringWithFormat:
      @"https://shopee.tw/api/v4/pdp/get_pc?display_model_id=0&item_id=%@&model_selection_logic=3&shop_id=%@&tz_offset_in_minutes=480&detail_level=0",
      itemId, shopId];
  ahaStep(@"任务:领到单");
  ahaLog(@"s", @"抢单成功");
  ahaRefreshUI();

  // 导航 = Ajie openCurrentTask 0x2f7fc 时序 1:1 + 页面真跳验证：
  // popToRootViewControllerIfNeeded → 0.35s → 内路由（4 route × navigate/push）
  // → 1.2s 后验证 topVC 是否真的变了（invoke 不抛异常≠页面跳了）
  // → 没变 → 商品直开三连 → 再验证 → 全无效 → Universal Link 兜底（页面必须真开）
  dispatch_async(dispatch_get_main_queue(), ^{
    ahaPopToRootIfNeeded();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
      UIViewController *before = ahaResolvedTopVC();
      // v0.5.25 = Ajie openCurrentTask 0x2f7fc+navigateWithBTManagerToRoute 0x23fb0 逐指令对齐：
      // Ajie 主入口传入的 route 是 'rn/PRODUCT_PAGE?itemid=%@&shopid=%@'（无下划线），
      // navigateWith 把它排在数组第 0 位，后面才是 item_id/good_id/shopid/PRODUCT_PAGE 四个备胎。
      // 我们此前从没发过第 0 位的无下划线格式——若解析器只认 itemid/shopid，
      // 我们打开的就是无商品参数的空壳 RN 页（页开了、数据死，症状完全吻合）
      NSArray *routes = @[
        [NSString stringWithFormat:@"rn/PRODUCT_PAGE?itemid=%@&shopid=%@", itemId, shopId],   // ← Ajie 主格式
        [NSString stringWithFormat:@"rn/PRODUCT_PAGE?item_id=%@&shop_id=%@", itemId, shopId],
        [NSString stringWithFormat:@"rn/PRODUCT_PAGE?good_id=%@&shop_id=%@", itemId, shopId],
        [NSString stringWithFormat:@"rn/PRODUCT_PAGE?shopid=%@&itemid=%@", shopId, itemId],
        [NSString stringWithFormat:@"PRODUCT_PAGE?itemid=%@&shopid=%@", itemId, shopId],
      ];
      BOOL invoked = NO;
      ahaStep(@"导航:开始");
      @try { invoked = ahaTryRouteInvokes(routes); } @catch (NSException *e) {
        ahaLog(@"e", [NSString stringWithFormat:@"导航异常:%@", e.reason]);
      }
      ahaStep(@"导航:结束");
      if (!invoked) {
        ahaLog(@"w", @"进入详情重试");
        ahaOpenUniversalLink(shopId, itemId, taskUrl);
        ahaObserveBegin();
        return;
      }
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
          dispatch_get_main_queue(), ^{
        UIViewController *after = ahaResolvedTopVC();
        if (after && after != before) {
          ahaLog(@"i", @"进入详情成功");   // v0.5.30 四状态：抢单成功/进入详情成功/提交中/提交成功
          ahaObserveBegin();
          return;
        }
        // route「调用成功」但页面没动 → 商品直开三连 → 再验证 → UL 兜底
        BOOL d = NO;
        @try { d = ahaTryDirectOpens(shopId, itemId); } @catch (__unused NSException *e) { d = NO; }
        if (!d) {
          ahaLog(@"w", @"进入详情重试");
          ahaOpenUniversalLink(shopId, itemId, taskUrl);
          ahaObserveBegin();
          return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
          UIViewController *after2 = ahaResolvedTopVC();
          if (after2 && after2 != before) {
            // v0.5.28 精简：商品直开成功不再刷日志
          } else {
            ahaLog(@"w", @"进入详情重试");
            ahaOpenUniversalLink(shopId, itemId, taskUrl);
          }
          ahaObserveBegin();
        });
      });
    });
  });

  NSString *pid = self.cfg[@"pid"] ?: @"";
  NSString *jxServer = [NSString stringWithFormat:@"%@", t[@"jxServer"] ?: @""];
  NSString *subTok   = [NSString stringWithFormat:@"%@", t[@"submitToken"] ?: @""];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    // 等 app 自己的 get_pc 回包（最长 15 秒，0.5s 轮询；睡在后台队列，不堵 _q / 主线程）
    __block NSString *body = nil;
    for (int i = 0; i < 30 && !body; i++) {
      [NSThread sleepForTimeInterval:0.5];
      body = [[AHACapture shared] bodyForShop:shopId item:itemId];
    }
    NSString *via = @"app截包";
    if (!body) {
      // app 抓包超时 = 页面没开/没发 get_pc → 计入连续失败（Ajie handleNoDataCapture 语义）
      dispatch_async(self.q, ^{ [self noteCaptureFailure:NO]; });
      dispatch_async(dispatch_get_main_queue(), ^{ ahaObserveFlush(); });   // v0.5.16：超时点把观察窗收集到的 URL 全部刷出
      ahaLog(@"i", @"明细超时，直调兜底");
      ahaStep(@"任务:DirectPDP兜底");
      body = [self directFetchShop:shopId item:itemId taskUrl:taskUrl];
      via = @"DirectPDP";
      if (!body) ahaLog(@"w", @"直连失败，不计入风控");
    }
    if (body) dispatch_async(self.q, ^{ self.failStreak = 0; gPool.risk = NO; });
    // 白板自清理：这一单走完（成/败都一样），把商品页退掉——
    // 加载失败的商品页会弹「重新載入」白板，一层层叠下去屏幕就黑了
    dispatch_async(dispatch_get_main_queue(), ^{
      UIViewController *top = ahaResolvedTopVC();
      while (top && top.presentedViewController) [top dismissViewControllerAnimated:NO completion:nil];
      ahaRouteBackOnce();
    });
    dispatch_async(self.q, ^{
      if (!body) {
        ahaLog(@"w", @"采集超时，任务回池");
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
      ahaLog(@"i", @"提交中");   // v0.5.30 四状态：抢单成功/进入详情成功/提交中/提交成功
      [self submit:taskId taskUrl:pcUrl result:body itemId:itemId acct:acct jxServer:jxServer token:subTok];
    });
  });
}

// —— Direct PDP：重放 app 上下文调商品接口（Ajie 的核心兜底）——
// v0.5.24：优先重放 app 刚发出的真实 pdp/get URL（get_pc 已是老端点，SGW 直接 418）；
// 90 秒内 app 发过 pdp 请求才有 fresh URL，否则回退 get_pc 模板
- (NSString *)directFetchShop:(NSString *)shopId item:(NSString *)itemId taskUrl:(NSString *)taskUrl {
  NSString *url = [[AHACapture shared] freshPdpURL];
  if (!url) {
    url = taskUrl;
    if ([url rangeOfString:kGetPcMark].location == NSNotFound)
      url = [NSString stringWithFormat:kGetPcTpl, itemId, shopId];
  }
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
        ahaLog(@"w", [NSString stringWithFormat:@"直调失败 HTTP %ld", (long)hr.statusCode]);
    } else if (e) {
      ahaLog(@"w", [NSString stringWithFormat:@"直调网络错误：%@", e.localizedDescription]);
    }
    dispatch_semaphore_signal(sem);
  }] resume];
  dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(22 * NSEC_PER_SEC)));
  if (out.length > 100) {
    if (ahaPdpBodyValid(out)) [[AHACapture shared] storeBody:out shop:shopId item:itemId];
    else { ahaLog(@"w", @"直调回包字段不全，不提交"); out = nil; }   // v0.5.31 十字段门
  } else out = nil;
  return out;
}

// —— v0.5.32 第二刀：Ajie 设备号同款——稳定 device_id（UserDefaults 持久化），
// device_id 与 fingerprint_key 共用同一值（Ajie 0x34f38~0x34fd8 两次取 deviceID 的实测结构）
static NSString *ahaDeviceID(void) {
  static NSString *did = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSString *k = @"aha_device_id";
    did = [[NSUserDefaults standardUserDefaults] stringForKey:k];
    if (did.length == 0) {
      did = [[NSUUID UUID] UUIDString];
      [[NSUserDefaults standardUserDefaults] setObject:did forKey:k];
    }
  });
  return did;
}
static NSString *ahaNewUuid(void) { return [[NSUUID UUID] UUIDString]; }

// —— 提交：优先聚星直传（省跨境流量），失败回退中枢代交 ——
- (void)submit:(NSString *)taskId taskUrl:(NSString *)taskUrl result:(NSString *)result
        itemId:(NSString *)itemId acct:(NSString *)acct
      jxServer:(NSString *)jxServer token:(NSString *)token {
  if (jxServer.length > 8 && token.length > 8) {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:[jxServer stringByAppendingString:@"/api/task/submit/v2"]]];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 60;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    // v0.5.32 报文字段 1:1 对齐 Ajie submitCapturedJSONString（0x34a00~0x352a0 实测取值）：
    // source='ios_submit' platform='ios' device_type='ios' submit_id=任务号
    // task_id/deal_id=任务号 trace_id=每次新UUID item_id=商品号
    // username/accountId=子账号 token=子账号token device_id=fingerprint_key=稳定设备号
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:
        @{ @"appVersion": @"vv2", @"url": taskUrl, @"result": result,
           @"source": @"ios_submit", @"platform": @"ios", @"device_type": @"ios",
           @"submit_id": taskId, @"task_id": taskId, @"deal_id": taskId,
           @"trace_id": [NSString stringWithFormat:@"tr_%@", ahaNewUuid()],
           @"item_id": itemId, @"username": acct, @"accountId": acct, @"token": token,
           @"device_id": ahaDeviceID(), @"fingerprint_key": ahaDeviceID(),
           @"bundle_id": @"com.aha.mobile" } options:0 error:nil];
    static NSURLSession *sess = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      sess = AhaSession([NSURLSessionConfiguration ephemeralSessionConfiguration]);   // v0.5.24 隔离
    });
    [[sess dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
      dispatch_async(self.q, ^{
        BOOL ok = NO;
        NSString *codeTxt = @"无回包", *msgTxt = @"";
        // v0.5.27 判定实证（19:08 三单聚星完成、回包 data.code=无）：成功回包 data 里没有 code 字段！
        // 与 PC collectSubmit 同构：信封 code==='200'（字符串）+ 有 data + 非 ERROR；
        // 失败探针回包 {"code":"200","data":{"code":"ERROR","msg":"结果有误"}}
        NSString *raw = (d.length ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"") ?: @"";
        NSString *rawHead = raw.length > 80 ? [[raw substringToIndex:80] stringByAppendingString:@"…"] : raw;
        id o = raw.length ? [NSJSONSerialization JSONObjectWithData:[raw dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : nil;
        if ([o isKindOfClass:[NSDictionary class]]) {
          NSDictionary *dt = [o[@"data"] isKindOfClass:[NSDictionary class]] ? (NSDictionary *)o[@"data"] : nil;
          id m = dt ? (dt[@"msg"] ?: o[@"msg"]) : o[@"msg"];
          msgTxt = [m isKindOfClass:[NSString class]] ? (NSString *)m : @"";
          NSString *env = [NSString stringWithFormat:@"%@", o[@"code"] ?: @""];
          NSString *dcs = dt ? [NSString stringWithFormat:@"%@", dt[@"code"] ?: @""] : @"";
          ok = [env isEqualToString:@"200"] && dt && ![dcs isEqualToString:@"ERROR"];
          codeTxt = dcs.length ? dcs : (dt ? @"data有(无code)" : @"data无");
        } else if (raw.length) {
          codeTxt = rawHead;
        }
        if (!ok && raw.length) {
          if ([raw containsString:@"或者已经完成过了"]) ok = YES;
          else if (([raw containsString:@"已保存"] || [raw containsString:@"success"])
                   && ![codeTxt isEqualToString:@"ERROR"]) ok = YES;
        }
        if (ok) {
          [self markOk:taskId via:@"聚星直传" resp:rawHead];
        } else {
          // v0.5.30 精简：失败一行，带聚星原因（长原文只留在中枢 audit）
          NSString *why = msgTxt.length ? msgTxt : (codeTxt.length ? codeTxt : @"无回包");
          ahaLog(@"w", [NSString stringWithFormat:@"提交失败：%@", why]);
          [self hubSubmit:taskId taskUrl:taskUrl result:result];
        }
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
      if (j && [j[@"ok"] boolValue]) [self markOk:taskId via:@"中枢代交" resp:@""];
      else {
        ahaLog(@"e", [NSString stringWithFormat:@"提交失败：%@",
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

- (void)markOk:(NSString *)taskId via:(NSString *)via resp:(NSString *)resp {
  self.ok++;
  self.taskLine = @"";
  (void)taskId; (void)via; (void)resp;   // v0.5.30 精简：成功只留一行计数，回包原文不再进面板
  ahaLog(@"s", [NSString stringWithFormat:@"提交成功 %ld", (long)self.ok]);
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
@property(nonatomic, strong) UIView *logBox;
@property(nonatomic, strong) UILabel *logLabel;
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
  p.backgroundColor = AhaColor(16, 18, 24, 0.62);   // v0.5.28 半透明（用户指定，Ajie 同款质感）
  p.layer.cornerRadius = 14;
  p.clipsToBounds = YES;
  p.layer.borderWidth = 1;
  p.layer.borderColor = AhaColor(255, 255, 255, 0.12).CGColor;
  self.panel = p;

  // header（拖动区 + 设置 + 收起）
  UIView *hd = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 40)];
  hd.backgroundColor = AhaColor(28, 34, 48, 0.72);
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

  // 日志窗（v0.5.30：弃用 UITextView 滚动——高频重写+折行会让 contentOffset 滚出内容区变白屏；
  // 改底部锚定 UILabel：内容永远从底部往上排，超高就裁掉最旧的，物理上不可能出现空白）
  self.logBox = [[UIView alloc] initWithFrame:CGRectZero];
  self.logBox.backgroundColor = AhaColor(0, 0, 0, 0.35);
  self.logBox.layer.cornerRadius = 8;
  self.logBox.clipsToBounds = YES;
  [p addSubview:self.logBox];
  self.logLabel = [[UILabel alloc] initWithFrame:CGRectZero];
  self.logLabel.numberOfLines = 0;
  self.logLabel.backgroundColor = [UIColor clearColor];
  self.logLabel.textColor = AhaColor(235, 235, 235, 0.92);
  self.logLabel.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
  [self.logBox addSubview:self.logLabel];

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

  ahaLog(@"s", gPure
      ? @"AHA 已注入（纯净模式：无网络钩子，设置⚙里可切完整模式）"
      : @"AHA 已注入（完整模式：网络钩子已装）");
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
  UIAlertController *a = [UIAlertController alertControllerWithTitle:@"服务器地址 / 验券账号"
      message:@"第二格填验券服务的「后端用户ID」，留空 = 关闭优惠券检测" preferredStyle:UIAlertControllerStyleAlert];
  [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
    f.placeholder = @"https://140.235.98.220:29690";
    f.text = gPool.cfg[@"server"] ?: @"";
  }];
  [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
    f.placeholder = @"优惠券账号ID（留空关闭验券）";
    f.text = gPool.cfg[@"couponAcct"] ?: @"";
  }];
  [a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *act) {
    NSString *sv = a.textFields[0].text ?: @"";
    if (sv.length) {
      gPool.cfg[@"server"] = sv;
      ahaLog(@"i", @"服务器已保存");
    }
    gPool.cfg[@"couponAcct"] = [a.textFields[1].text stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
    [gPool saveCfg];
    if ([gPool.cfg[@"couponAcct"] length]) ahaLog(@"i", @"优惠券检测已开启：领取任务前先检测优惠券数据");
  }]];
  // v0.5.22 纯净/完整模式切换（二分定位「装上即全网死」，切换后重启虾皮生效）
  [a addAction:[UIAlertAction actionWithTitle:(gPure ? @"切换到完整模式" : @"切换到纯净模式")
      style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *act) {
    BOOL want = !gPure;
    [[NSUserDefaults standardUserDefaults] setObject:@(want) forKey:@"aha_pure_v1"];
    ahaLog(@"w", want
        ? @"已切到完整模式（网络钩子将装上）：杀掉虾皮进程重开生效"
        : @"已切到纯净模式（卸掉所有网络钩子）：杀掉虾皮进程重开生效");
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
  self.logBox.frame   = CGRectMake(12, y, w - 24, h - y - 14);
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
  // v0.5.30 日志渲染：底部锚定 UILabel（不滚动、不设 contentOffset，修「日志消失」）
  NSArray *lines = gPool.logLines;
  NSString *txt = [lines componentsJoinedByString:@"\n"];
  if (![txt isEqualToString:self.logLabel.text]) self.logLabel.text = txt;
  CGFloat bw = self.logBox.bounds.size.width, bh = self.logBox.bounds.size.height;
  if (bw > 1 && bh > 1) {
    CGSize s = [self.logLabel sizeThatFits:CGSizeMake(bw - 8, CGFLOAT_MAX)];
    // 底边固定贴着日志框底部：内容多就向上溢出、被 logBox 裁掉最旧的行（永远看得到最新状态）
    self.logLabel.frame = CGRectMake(4, bh - s.height - 4, bw - 8, s.height);
  }
}

@end

static void ahaRefreshUI(void) {
  // 日志高频刷新合并：0.25s 内多条日志只刷一次（修日志乱跳）
  static dispatch_source_t timer; static BOOL pending = NO;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC, 100 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
      if (pending && gUI) { pending = NO; [gUI refresh]; }
    });
    dispatch_resume(timer);
  });
  pending = YES;   // 到点统一刷；立即刷会被 250ms 合并窗吸收
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

__attribute__((unused)) static void ahaInstallCrashCatcher(void) {
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
  // v0.5.23：默认完整模式——钩子面已削成与 Ajie 完全等价（3 钩 + delegate 挂钩），
  // 崩溃捕获器不再装（Ajie 符号表实证：无 signal/sigaction/UncaughtExceptionHandler）。
  // 纯净模式开关保留（aha_pure_v1），留作以后二分用
  id pv = [[NSUserDefaults standardUserDefaults] objectForKey:@"aha_pure_v1"];
  gPure = pv ? [pv boolValue] : NO;
  if (!gPure) {
    %init(gNetCapture);        // completionHandler 双变体（Ajie 0x1423c/0x1425c 1:1）
    %init(gNetJSON);           // NSJSONSerialization 元类钩（Ajie 0x14290 1:1）
    %init(gNetSession);        // sessionWithConfiguration 元类钩 → delegate 挂钩（Ajie 0x41d7c 同款）
  }
  gPool = [AHAPool shared];
  if (!gPure) ahaInstallCrashCatcher();   // v0.5.34：装回崩溃捕获器（诊断进详情闪退，根因下次启动面板直接显示）
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
    gUI = [AHAUI shared];
    [gUI boot];
    ahaReportLastCrash();    // 面板起来后第一时间汇报上次闪退根因
  });
}
