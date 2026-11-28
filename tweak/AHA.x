// AHA.x — Shopee app 内采集客户端（导航 = Ajie 逐字复刻 + 面包屑诊断）
//
// v0.5.56（2026-11-27）：虚拟设备指纹功能整体下线（用户令）。
//   血泪实锤：种子在「插件登录」时写入，此时 Shopee 已跑起来、设备身份早已上报绑定，
//   IDFV 中途变脸 → 服务端设备校验对不上 → 首页数据不下发白屏/掉登（实机复现）。
//   已删：IDFV/IDFA/追踪钩、种子派生、登录补种、设置面板开关、重置指纹（双清扫+exit 重启）、
//   解绑登录设备（标题双击+反欺诈两接口）；ctor 一次性清残留键 aha_fp_seed/aha_fp_acct/aha_fp_on。

//   ④ 性能瘦身（App 整体卡主犯削除）：delegate 累积表改按 Class 直接做键（省掉每 chunk 一次
//      NSStringFromClass 分配）；pdp 上下文快照只在 URL 变化时重拷（旧版每 chunk 全头拷贝）；
//      日志渲染只排最末 48 行（底部锚定裁掉旧行本来不可见，白白排版 400 行）
//
// v0.5.6 关键改动（对照 Ajie 0.1.3 反汇编逐条对齐）：
// v0.5.13（2026-11-24）：导航/风控/日志/验券 全面对照 Ajie 反汇编 1:1 重做——
//   导航=openCurrentTask 时序（popToRoot→0.35s→内路由→失败 Universal Link openURL 兜底，不再 Direct PDP 当导航用）；
//   风控=删弹窗，266900002 按正常响应提交，90309999 自动停，直连失败不计风控，连续 2 次无数据自动暂停；
//   v0.5.64 等包节奏=5s/轮×重试2次（重进商品页），3轮全空+直连终审也空=任务回池+脚本暂停（用户令）
//   v0.5.66 直连终审（Ajie 0.1.3 Direct PDP 反汇编 0x3d588/0x2bcfc/0x2fd04 对齐）：
//     3轮截包全空后用记住的真实请求头直连 get_pc——回包=商品数据（提交）/266900002（死商品→提交）/
//     90309999（墙→回池+暂停）。实锤场景：页面渲染完整但 app 不发数据请求（缓存渲染/反爬静默），截包永远空
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
#import <QuartzCore/QuartzCore.h>   // v0.5.36 CABasicAnimation（风控横幅闪烁）
#import <Foundation/Foundation.h>
#import <Security/Security.h>           // v0.5.45 Keychain 清扫
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
// v0.5.50：Ajie 0x2729c 候选表第二条模板（get_pc 失效时的老端点兜底）
static NSString *const kGetTpl    = @"https://shopee.tw/api/v4/pdp/get?itemid=%@&shopid=%@&tz_offset_in_minutes=480";

@class AHAPool;
@class AHACapture;
@class AHAPanel;
@class AHAUI;

static AHAPool *gPool = nil;
static BOOL gPanelDragging = NO;   // v0.5.39 面板拖拽中：期间跳过日志重排版（sizeThatFits 叠在手指帧上会卡手）
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
static NSInteger gObsPdp = 0;      // v0.5.52：窗口内 pdp 端点请求数（超时诊断：页面到底发没发）
static void ahaObserveRecv(void) {
  if (gObserveUntil && [gObserveUntil compare:[NSDate date]] == NSOrderedAscending) gObsRecv++;
}
static NSMutableArray *gObsURLs = nil;
static BOOL gObsFlushed = NO;
// v0.5.59 窗口回包记录器（用户令：搞清「你尋找的商品已不存在」页面到底发什么包）：
// 每个回包记 URL+状态码+长度+报文前200字，miss 上传时一并传中枢存档，事后分析补识别规则
static NSMutableArray *gMissResp = nil;
static void ahaObserveFlush(void) {
  if (gObsFlushed) return;
  gObsFlushed = YES;
  // v0.5.28 Ajie 风格精简：观察窗只做静默收集，不再刷屏（采集链路已通，诊断期结束）
  [gObsURLs removeAllObjects];
}
static void ahaObserveBegin(void) {
  gObserveUntil = [NSDate dateWithTimeIntervalSinceNow:30];
  gObsCount = 0; gObsAny = 0; gObsShopee = 0; gObsJSON = 0; gObsRecv = 0; gObsPdp = 0; gObsFlushed = NO;
  if (!gObsURLs) gObsURLs = [NSMutableArray array]; else [gObsURLs removeAllObjects];
  if (!gMissResp) gMissResp = [NSMutableArray array]; else [gMissResp removeAllObjects];   // v0.5.59
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
  if ([u rangeOfString:kPdpMark].location != NSNotFound) gObsPdp++;   // v0.5.52 pdp 请求计数
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
static void ahaRefreshNow(void);                          // v0.5.43 绕过 250ms 合并窗，立刻刷（按钮状态变更用）
static void ahaStep(NSString *tag);                       // v0.5.34 前置声明（钩子门面包屑在定义之前调用）

#pragma mark - 池客户端（接口声明）

@interface AHAPool : NSObject
@property(nonatomic, strong) NSMutableDictionary *cfg;
@property(nonatomic, strong) NSDate *lastRiskAlert;
@property(nonatomic, assign) BOOL running, connected, resting, risk;
@property(nonatomic, assign) NSInteger lastRestTaken;   // v0.5.58 休息死循环修复：上次触发休息时的 taken
@property(nonatomic, assign) BOOL connecting;   // v0.5.43 点了开始→登录回来之间：按钮亮「连接中」，防重复点
@property(nonatomic, assign) NSInteger taken, ok, failStreak;   // 连续无数据计数（Ajie consecutivePDPFailures 1:1）
@property(nonatomic, assign) NSUInteger logVer;   // v0.5.44 日志版本号：渲染跟版本走，不再全文比对
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
- (NSDictionary *)bodyInfoForShop:(NSString *)shop item:(NSString *)item;   // v0.5.49 body+来源URL
- (void)noteNoItem:(NSString *)body url:(NSString *)url;    // v0.5.53 noitem 信号（错误报文原样提交用）
- (void)clearNoItem;                                        // v0.5.53 新任务开始清上一单信号
- (NSDictionary *)takeNoItemForShop:(NSString *)shop item:(NSString *)item;   // v0.5.53 归属匹配才返回（取走即清）
- (NSDictionary *)peekNoItem;                               // v0.5.53 诊断：最后一条 error 回包（不管归属）
- (void)storeBody:(NSString *)body shop:(NSString *)shop item:(NSString *)item;
- (void)storeBody:(NSString *)body shop:(NSString *)shop item:(NSString *)item url:(NSString *)url;   // v0.5.49
- (NSDictionary *)contextCopy;
@end

// —— v0.5.54 noitem 信号提取（用户令：能提交的都提交；窗口端 v7.121/v7.134 生产先例）：
// 聚星任务商品被删/下架/无数据时，Shopee 接口回 {"error":...} 短报文，页面显示「商品已不存在」。
// 业务规则：错误报文原样提交聚星。任何非零 error 都收（v0.5.54 放宽：不只 266900002），
// 唯独 90309999 验证墙绝不提交（墙下交包=风控升级）；containsString 预筛免 JSON 解析开销。
static NSDictionary *ahaNoItemFromBody(NSString *body, NSString *url) {
  if (body.length == 0 || body.length > 262144) return nil;
  if ([body rangeOfString:@"\"error\""].location == NSNotFound) return nil;
  NSData *d = [body dataUsingEncoding:NSUTF8StringEncoding];
  id o = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
  if (![o isKindOfClass:[NSDictionary class]]) return nil;
  id e = o[@"error"];
  if (![e respondsToSelector:@selector(integerValue)]) return nil;
  NSInteger ec = [e integerValue];
  if (ec == 0 || ec == 90309999) return nil;   // 0=正常回包；90309999=验证墙
  return @{ @"body": body, @"url": url ?: @"" };
}

@implementation AHACapture {
  NSMutableDictionary *_bodies;   // @"shop|item" -> @{ body, at }
  NSMutableDictionary *_ctx;      // app 自己 pdp 请求头快照
  NSString *_pdpURL;              // v0.5.24：app 真实 pdp 请求 URL
  NSDate *_pdpURLAt;
  NSString *_ctxURL;              // v0.5.45：上下文快照对应请求 URL（同 URL 不重拷）
  NSDictionary *_noItem;          // v0.5.53：noitem 信号 @{ body, url, at }（取走即清）
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
  // v0.5.45 性能：同一 URL 的每个回包 chunk 都会进来，全头拷贝每 chunk 一次纯浪费——
  // URL 没变就跳过（Direct PDP 只需要最新一套头，同请求内头不会中途变）
  NSString *u = req.URL.absoluteString ?: @"";
  @synchronized (self) {
    if (u.length && [_ctxURL isEqualToString:u]) return;
    _ctxURL = [u copy];
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
  if (!data.length) return;
  NSHTTPURLResponse *hr = [resp isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)resp : nil;
  NSInteger code = hr.statusCode;
  NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  // v0.5.59 窗口回包记录器：全端点都记（含 pdp），miss 分析要看「这种页面到底打了什么」
  if (gMissResp) {
    @synchronized (gMissResp) {
      if (gMissResp.count < 25) {
        NSString *pre = body.length ? body : @"";
        if (pre.length > 200) pre = [pre substringToIndex:200];
        [gMissResp addObject:@{ @"u": u ?: @"", @"c": @(code), @"len": @(data.length), @"p": pre }];
      }
    }
  }
  if (!body.length) return;
  // v0.5.53 noitem 扫描：死商品页不打 pdp 接口（诊断实锤 pdp请求=0），错误信号在任意端点回包里——
  // 非 pdp 回包扫完即走，pdp 回包继续走下方原逻辑
  if (!isPc) {
    NSDictionary *ni = ahaNoItemFromBody(body, u);
    if (ni) [self noteNoItem:ni[@"body"] url:ni[@"url"]];
    return;
  }

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
    [self storeBody:body shop:shop item:item url:req.URL.absoluteString];   // v0.5.49 completionHandler 通道带来源 URL
}

- (void)storeBody:(NSString *)body shop:(NSString *)shop item:(NSString *)item {
  [self storeBody:body shop:shop item:item url:nil];
}

// v0.5.49：包体连同「产出它的真实 URL」一起存（Ajie submitCapturedJSONString:sourceURL:
// 0x372a0 实证：提交报文 url/rawResponseUrl = 真实来源 URL，不是构造模板——审核按这个回访比对）
- (void)storeBody:(NSString *)body shop:(NSString *)shop item:(NSString *)item url:(NSString *)url {
  @synchronized (self) {
    _bodies[[NSString stringWithFormat:@"%@|%@", shop, item]] =
        @{ @"body": body ?: @"", @"at": [NSDate date], @"url": url ?: @"" };
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
    NSDate *at = e[@"at"];
    if (e && at && -[at timeIntervalSinceNow] < 90) out = e[@"body"];   // v0.5.52 时效门同上
  }
  return out;
}

// v0.5.52 时效门（Ajie 语义对齐）：Ajie 的包只在 waitingForPDP（当前任务等待期）捕获，
// 天然不会旧；我们的 _bodies 常驻缓存，同商品复发任务会把**几分钟/几小时前的旧包**
// 当本任务的包提交——页面走缓存不发请求时尤其如此。旧包价格/库存与领单时点不符
// = 聚星审核拒的直接嫌疑。只认 90 秒内的包（与 freshPdpURL 的 TTL 一致），旧的返回 nil
// 让等待循环落到直连/回池，绝不用旧包凑数。
- (NSDictionary *)bodyInfoForShop:(NSString *)shop item:(NSString *)item {
  __block NSDictionary *out = nil;
  @synchronized (self) {
    NSDictionary *e = _bodies[[NSString stringWithFormat:@"%@|%@", shop, item]];
    NSDate *at = e[@"at"];
    if (e && at && -[at timeIntervalSinceNow] < 90)
      out = @{ @"body": e[@"body"] ?: @"", @"url": e[@"url"] ?: @"",
               @"age": @((int)-[at timeIntervalSinceNow]) };
  }
  return out;
}

// —— v0.5.53 noitem 信号：任意端点回包 error=266900002 → 存（等包循环 0.5s 轮询消费）——
// 归属校验在消费端做（URL query 或报文顶层的 item/shop 必须等于当前任务），防其它页面的错误串号
- (void)noteNoItem:(NSString *)body url:(NSString *)url {
  if (body.length == 0) return;
  @synchronized (self) { _noItem = @{ @"body": body, @"url": url ?: @"", @"at": [NSDate date] }; }
}
- (void)clearNoItem {
  @synchronized (self) { _noItem = nil; }
}
- (NSDictionary *)peekNoItem {
  @synchronized (self) { return _noItem; }
}
- (NSDictionary *)takeNoItemForShop:(NSString *)shop item:(NSString *)item {
  @synchronized (self) {
    NSDictionary *e = _noItem;
    if (!e) return nil;
    NSDate *at = e[@"at"];
    if (!at || -[at timeIntervalSinceNow] > 60) return nil;   // 60s 内有效，防旧信号串号
    NSString *u = e[@"url"];
    NSString *iid = nil, *sid = nil;
    NSURLComponents *uc = u.length ? [NSURLComponents componentsWithString:u] : nil;
    for (NSURLQueryItem *qi in uc.queryItems ?: @[]) {
      NSString *n = qi.name.lowercaseString ?: @"";
      if ([n isEqualToString:@"item_id"] || [n isEqualToString:@"itemid"] || [n isEqualToString:@"itemids"]) iid = qi.value;
      if ([n isEqualToString:@"shop_id"] || [n isEqualToString:@"shopid"]) sid = qi.value;
    }
    if (!iid.length || !sid.length) {   // URL query 无 id → 看报文顶层（网关 POST 类请求）
      NSData *d = [(NSString *)e[@"body"] dataUsingEncoding:NSUTF8StringEncoding];
      id o = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
      if ([o isKindOfClass:[NSDictionary class]]) {
        if (!iid.length) { iid = [NSString stringWithFormat:@"%@", o[@"item_id"] ?: o[@"itemid"] ?: @""]; if ([iid isEqualToString:@"(null)"]) iid = @""; }
        if (!sid.length) { sid = [NSString stringWithFormat:@"%@", o[@"shop_id"] ?: o[@"shopid"] ?: @""]; if ([sid isEqualToString:@"(null)"]) sid = @""; }
      }
    }
    if (item.length && iid.length && ![iid isEqualToString:item]) return nil;
    if (shop.length && sid.length && ![sid isEqualToString:shop]) return nil;
    if (!iid.length && !sid.length) return nil;   // 完全无法归属 → 不提交（peekNoItem 诊断可看）
    _noItem = nil;   // 取走即清
    return e;
  }
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

// 真商品回包但字段不全 → 静默丢弃不入库（v0.5.37 用户令：不动手就不该有日志，门照常工作）
static void ahaBadBodyLog(NSString *body, NSString *shop, NSString *item) {
  return;
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
    dispatch_async(gPool.q, ^{ gPool.risk = NO; gPool.failStreak = 0; });   // v0.5.52 合并冗余 dispatch（原两行重复入队）
    if (!ahaPdpBodyValid(body)) { ahaBadBodyLog(body, sid, iid); return; }   // v0.5.31 十字段门
    // v0.5.49 来源 URL：JSON 门拿不到请求对象，用 rememberPdpURL 记下的 app 真实 pdp URL
    //（请求先发后解析，此刻必然已在）——Ajie 提交报文的 url/rawResponseUrl 就是这个
    [self storeBody:body shop:sid item:iid url:[[AHACapture shared] freshPdpURL]];
  } @catch (__unused NSException *e) { /* 非目标 JSON，静默 */ }
}

// —— Ajie 1:1：delegate 会话的原始字节（didReceiveData 累积 + didComplete 收尾）在这里落库——
// 不管虾皮用什么解析器，原始回包已在手；shop/item 优先从 URL query 取，取不到再按 JSON 形状识别
- (void)inspectRawBody:(NSString *)body url:(NSString *)u request:(NSURLRequest *)req {
  if (!gPool || body.length == 0) return;
  @try {
    // u 为空 = shp 自家回调通道（拿不到 NSURL），交给下面的形状识别把关
    if (u.length && [u rangeOfString:kPdpMark].location == NSNotFound) {   // v0.5.17：任意 /api/v4/pdp/ 端点
      NSDictionary *ni = ahaNoItemFromBody(body, u);   // v0.5.53 noitem 扫描（同 inspectData）
      if (ni) [self noteNoItem:ni[@"body"] url:ni[@"url"]];
      return;
    }
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
    [self storeBody:body shop:shop item:item url:u];   // v0.5.49 RAW 门自带请求 URL
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

// v0.5.46 长跑卡顿主修①：NSURLSession 在 invalidate 前会自我保活（self-retain），
// 旧版直连 fetch / 券探测 / 解绑每次新建会话且从不 invalidate —— 每单漏 1~2 个
// 会话（含连接池与 socket），跑几小时几百个，内存与句柄双涨 = 用户报「跑久了卡」。
// 改全插件共享一个 ephemeral 会话（配置同旧版，cookie/缓存隔离不破坏）。
static NSURLSession *AhaSharedSession(void) {
  static NSURLSession *s; static dispatch_once_t once;
  dispatch_once(&once, ^{ s = AhaSession([NSURLSessionConfiguration ephemeralSessionConfiguration]); });
  return s;
}

#pragma mark - App 内路由导航（v0.5.6 = Ajie 反汇编逐字复刻，绝不跳出 app）

// —— 面包屑：每个关键步骤先把名字写进 NSUserDefaults，闪退后下次启动就能报「死在哪一步」——
// v0.5.46 长跑卡顿主修②：旧版每次都 synchronize 强制落盘，而面包屑挂在钩子热路径
//（JSON门/RAW门/导航各步，每个网络回包都触发）= 每回包一次磁盘 I/O，跑久了 I/O 压力拖慢全 app。
// 改：同 tag 连续跳过 + 去 synchronize（系统定期自动落盘，崩溃诊断价值不变——只丢最后一条的落盘时机）。
static void ahaStep(NSString *tag) {
  @try {
    static NSString *last = nil;
    if (last && [last isEqualToString:tag]) return;
    [[NSUserDefaults standardUserDefaults] setObject:tag forKey:@"aha_step_v1"];
    last = tag;
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

// —— v0.5.56 页面级「商品已不存在」识别（对齐窗口端 collectNoItemPage v7.84）：
// 用户令：这类单直接提交错误报文，不点火直连；正常商品没抓到包的直连兜底照常。
// 文案表 1:1 抄窗口端（含繁简/桌面版「此商品不存在」无「已」字）。
// RN 文本不在 UILabel.text 里——在 RCTText/RCTParagraphComponentView 的 attributedText；
// 同时兜 UIAlertController 的 title/message（弹窗式提示）与 accessibilityLabel。
// 所有私有类读取 @try 包，读不到就跳过，绝不因识别逻辑崩掉采集。
static BOOL ahaNoItemTextMatch(NSString *s) {
  if (s.length == 0) return NO;
  // 「售完即止」是促销话术不是售罄标（数量有限售完即止=正常在售商品），先排除再匹配
  if ([s rangeOfString:@"售完即止"].location != NSNotFound) return NO;
  static NSArray *pats = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    pats = @[@"你尋找的商品已不存在", @"你寻找的商品已不存在", @"此商品已不存在", @"商品已不存在",
             @"此商品不存在", @"商品不存在", @"商品已下架", @"商品已被下架", @"查無此商品",
             @"查无此商品", @"找不到此商品", @"此商品已刪除", @"商品已刪除", @"商品已被刪除",
             @"此商品已删除", @"商品已删除", @"商品已被删除", @"此商品已停售", @"商品已停售",
             @"無法查看此商品", @"无法查看此商品", @"無法瀏覽此商品", @"无法浏览此商品",
             // v0.5.66 miss.jsonl 新增死单类型（页面渲染完整但 0 数据请求）：
             // 售完 badge（RNViewController 商品图角落）+ 卖家休假模式页
             @"售完", @"賣家目前正在休假模式", @"卖家目前正在休假模式", @"目前正在休假模式"];
  });
  for (NSString *p in pats) if ([s rangeOfString:p].location != NSNotFound) return YES;
  return NO;
}
// 返回命中的文案；outSample 回填页面文本样本（诊断用：没命中时打出来，看页面到底显示了什么）
// v0.5.59 全窗口扫（截图实锤修复：弹窗挂 4 秒没接住，旧版两处致命伤）——
//   ① 旧版 while 条件带 sample.length<400：死商品页背后是店铺页，页面文字很快填满 400 字
//      → 整棵树提前停遍历，弹窗排在后面根本没扫到（本次事故根因）
//   ② 旧版只走 keyWindow top.view：RN/自绘弹窗常直接 addSubview 到独立 UIWindow，
//      不在任何 VC 的 view 树里。现在扫所有窗口 + window 直挂子视图 + rootVC.view
static NSString *ahaPageNoItemText(NSString **outSample) {
  if (outSample) *outSample = nil;
  UIWindow *own = ahaOwnWin();
  NSMutableString *sample = [NSMutableString string];
  static NSArray *textSels = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    // UILabel.text 之外按选择器兜底读任意文本视图：RN Paper=attributedText(RCTText)，
    // RN Fabric=RCTParagraphComponentView，Texture/ASDK=attributedString
    textSels = @[@"attributedText", @"attributedString", @"text"];
  });
  int visited = 0;   // 全窗口共享遍历预算（v0.5.59）
  for (UIWindow *w in [UIApplication sharedApplication].windows) {
    if (w == own || w.hidden || w.alpha < 0.1f) continue;
    // ① 该窗口 VC 链上每一层的 UIAlertController title/message
    UIViewController *vc = w.rootViewController;
    for (int g = 0; vc && g < 8; g++) {
      if ([vc isKindOfClass:[UIAlertController class]]) {
        UIAlertController *a = (UIAlertController *)vc;
        if (ahaNoItemTextMatch(a.title)) return a.title;
        if (ahaNoItemTextMatch(a.message)) return a.message;
        if (a.title.length && sample.length < 400) [sample appendFormat:@"[弹窗]%@ ", a.title];
        if (a.message.length && sample.length < 400) [sample appendFormat:@"[弹窗]%@ ", a.message];
      }
      vc = vc.presentedViewController;
    }
    // ② window 直挂子视图 + rootVC.view 合并成一棵递归树
    //    匹配先于收集、遍历只受 view 数预算约束（样本 400 字上限只影响收集不影响继续扫）
    //    visited 全窗口共享预算 900（弹窗窗口 view 少通常最先扫完，开销与旧版同量级）
    NSMutableArray *stack = [NSMutableArray array];
    if (w.rootViewController.view) [stack addObject:w.rootViewController.view];
    for (UIView *sv in w.subviews) [stack addObject:sv];
    while (stack.count && visited < 900) {
      visited++;
      UIView *v = stack.lastObject;
      [stack removeLastObject];
      @try {
        NSMutableArray *texts = [NSMutableArray array];
        if ([v isKindOfClass:[UILabel class]]) {
          NSString *t = ((UILabel *)v).text;
          if (t.length) [texts addObject:t];
        }
        for (NSString *sel in textSels) {
          if (![v respondsToSelector:NSSelectorFromString(sel)]) continue;
          id o = [v valueForKey:sel];
          if ([o isKindOfClass:[NSAttributedString class]]) {
            NSAttributedString *nas = (NSAttributedString *)o;   // v0.5.59 id 上不能直接取属性(CI 编译错)
            if (nas.string.length) [texts addObject:nas.string];
          } else if ([o isKindOfClass:[NSString class]] && [(NSString *)o length] > 0) {
            [texts addObject:o];
          }
        }
        if (v.accessibilityLabel.length) [texts addObject:v.accessibilityLabel];
        for (NSString *t in texts) {
          if (ahaNoItemTextMatch(t)) return t;
          if (sample.length < 400 && t.length < 120) [sample appendFormat:@"%@ ", t];
        }
        for (UIView *sub in v.subviews) [stack addObject:sub];
      } @catch (__unused NSException *e) { /* 私有类读取失败跳过 */ }
    }
  }
  if (outSample) *outSample = sample;
  return nil;
}

// —— v0.5.61 死商品弹窗主动关掉（用户实证：弹窗一直不下去，挡住后续导航，监控有没有效也看不出来）——
// 页面识别命中并提交后，主线程再扫一遍窗口找弹窗本体关掉：
//   ① UIAlertController → dismiss（点 action 可能触发页面跳转，dismiss 最稳）
//   ② UIControl 按钮 title/accessibility 命中「回到上一步/返回/确定/知道了/好」→ sendActions 点击
//   ③ 非 UIControl 但可激活的视图（RN 按钮常是 RCTView）→ accessibilityActivate（公开 API，支持就响应）
// 弹窗能下去 = 页面监控实锤在工作；不下去也无所谓，下一单导航本身会盖过去
static void ahaDismissNoItemPopup(void) {
  dispatch_async(dispatch_get_main_queue(), ^{
    @try {
      UIWindow *own = ahaOwnWin();
      for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w == own || w.hidden || w.alpha < 0.1f) continue;
        UIAlertController *alert = nil;
        UIViewController *vc = w.rootViewController;
        for (int g = 0; vc && g < 8; g++) {
          if ([vc isKindOfClass:[UIAlertController class]]) { alert = (UIAlertController *)vc; break; }
          vc = vc.presentedViewController;
        }
        if (alert && alert.actions.count) { [alert dismissViewControllerAnimated:YES completion:nil]; continue; }
        NSMutableArray *stack = [NSMutableArray array];
        if (w.rootViewController.view) [stack addObject:w.rootViewController.view];
        for (UIView *sv in w.subviews) [stack addObject:sv];
        int visited = 0;
        while (stack.count && visited < 300) {
          visited++;
          UIView *v = stack.lastObject;
          [stack removeLastObject];
          NSString *cand = nil;
          if ([v isKindOfClass:[UIButton class]]) cand = ((UIButton *)v).currentTitle;
          if (cand.length == 0) cand = v.accessibilityLabel;
          if (cand.length) {
            BOOL btnHit = [cand containsString:@"回到上一步"] ||
                          [cand containsString:@"回上一步"] ||
                          ([cand containsString:@"返回"] && cand.length < 12) ||
                          ([cand containsString:@"確定"] && cand.length < 8) ||
                          ([cand containsString:@"确定"] && cand.length < 8) ||
                          ([cand containsString:@"知道了"] && cand.length < 8) ||
                          ([cand isEqualToString:@"好"] || [cand isEqualToString:@"OK"]);
            if (btnHit) {
              if ([v isKindOfClass:[UIControl class]]) {
                [(UIControl *)v sendActionsForControlEvents:UIControlEventTouchUpInside];
              } else {
                ((BOOL (*)(id, SEL))objc_msgSend)(v, NSSelectorFromString(@"accessibilityActivate"));
              }
              continue;
            }
          }
          for (UIView *sub in v.subviews) [stack addObject:sub];
        }
      }
    } @catch (__unused NSException *e) { /* 静默 */ }
  });
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
  // v0.5.35 防递归（进详情闪退根因）：v0.5.31 十字段门 ahaPdpBodyValid 内部调
  // JSONObjectWithData → 本钩再次触发 → inspectJSON → 门 → 又解析 → 无限递归 →
  // 栈溢出 SIGSEGV（只在回包含 data.item 的商品页触发，故「进详情必闪退」）。
  // 线程级守卫：inspectJSON 执行期间，本线程的所有解析直接透传，不再回进钩子。
  static __thread BOOL tInJSON = NO;
  if ([obj isKindOfClass:[NSDictionary class]] && !tInJSON) {
    tInJSON = YES;
    @try { [[AHACapture shared] inspectJSON:obj]; } @catch (__unused NSException *e) { /* 非目标 */ }
    tInJSON = NO;
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

// v0.5.48 血雷修复：v0.5.45 曾把这里改成「Class 对象做 NSDictionary 键」做性能优化——
// Class 不遵守 NSCopying，字典插入抛 NSInvalidArgumentException，又被外层 @catch 静默吞掉
// → 钩子装上了但原实现 IMP 永远存不进表 → 回包回调找不到 orig、直接不转发
// → app 自己的网络回调全断 → 首页永远等数据 = 白屏 + 整屏点不动（实机复现）。
// 现改为定长 C 表（Class 指针直接比对）：零分配、零 NSCopying 依赖，比两种字典写法都快。
#define AHA_MAX_SWZ 32
static Class sSwzDataCls[AHA_MAX_SWZ]; static IMP sSwzDataImp[AHA_MAX_SWZ]; static int sSwzDataN = 0;
static Class sSwzDoneCls[AHA_MAX_SWZ]; static IMP sSwzDoneImp[AHA_MAX_SWZ]; static int sSwzDoneN = 0;
static NSLock *sSwzLockObj = nil;
static NSLock *sSwzLock(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{ sSwzLockObj = [[NSLock alloc] init]; });
  return sSwzLockObj;
}
static NSMutableDictionary *gTaskBuf = nil;        // 兜底累积表：task 指针串 → 字节
static NSString *const kAhaBufKey = @"aha_buf_v1"; // piggyback 键

static BOOL ahaSwzHas(BOOL done, Class cls) {
  BOOL hit = NO;
  [sSwzLock() lock];
  int n = done ? sSwzDoneN : sSwzDataN;
  Class *cs = done ? sSwzDoneCls : sSwzDataCls;
  for (int i = 0; i < n; i++) if (cs[i] == cls) { hit = YES; break; }
  [sSwzLock() unlock];
  return hit;
}
static void ahaSwzPut(BOOL done, Class cls, IMP imp) {
  if (!cls || !imp) return;
  [sSwzLock() lock];
  int *np = done ? &sSwzDoneN : &sSwzDataN;
  Class *cs = done ? sSwzDoneCls : sSwzDataCls;
  IMP  *is = done ? sSwzDoneImp : sSwzDataImp;
  if (*np < AHA_MAX_SWZ) { cs[*np] = cls; is[*np] = imp; (*np)++; }
  [sSwzLock() unlock];
}
static IMP ahaOrigFor(BOOL done, id obj) {
  if (!obj) return NULL;
  Class cls = object_getClass(obj);
  if (!cls) return NULL;
  IMP out = NULL;
  [sSwzLock() lock];
  int n = done ? sSwzDoneN : sSwzDataN;
  Class *cs = done ? sSwzDoneCls : sSwzDataCls;
  IMP  *is = done ? sSwzDoneImp : sSwzDataImp;
  for (int i = 0; i < n; i++) if (cs[i] == cls) { out = is[i]; break; }
  [sSwzLock() unlock];
  return out;
}

static void ahaDelegateDidReceiveData(id self, SEL _cmd, id module, id requestLike, NSData *data);
static void ahaDelegateDidComplete(id self, SEL _cmd, id module, id requestLike, NSError *error);

static void ahaSwizzleDelegate(id delegate) {
  if (!delegate) return;
  @try {
    Class cls = object_getClass(delegate);
    if (!cls) return;
    if (!gTaskBuf) gTaskBuf = [NSMutableDictionary dictionary];
    if (ahaSwzHas(NO, cls) || ahaSwzHas(YES, cls)) return;   // 该类已挂钩，不重复包

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
      if (origData) ahaSwzPut(NO, cls, origData);
    }
    if ([delegate respondsToSelector:selDone]) {
      MSHookMessageEx(cls, selDone, (IMP)ahaDelegateDidComplete, &origDone);
      if (origDone) ahaSwzPut(YES, cls, origDone);
    }

    // v0.5.28 精简：装钩登记不再刷日志（cn/way 仅留作登记标记）
    static NSInteger sSwizzleLog = 0;
    sSwizzleLog += shpWay ? 1 : 0;
    (void)sSwizzleLog;
  } @catch (__unused NSException *e) { /* 静默 */ }
}

static void ahaDelegateDidReceiveData(id self, SEL _cmd, id module, id requestLike, NSData *data) {
  ahaObserveRecv();   // v0.5.19：回包事件计数（delegate 通道）
  IMP orig = ahaOrigFor(NO, self);
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
  IMP orig = ahaOrigFor(YES, self);
  if (orig)
    ((void (*)(id, SEL, id, id, NSError *))orig)(self, _cmd, module, requestLike, error); // Ajie 同序
  @try {
    if (error) {
      // v0.5.37：静默——视频 CDN 取消(-999)/网络抖动这类错误与采集无关，刷屏全是噪音；
      // 失败的回包本来也过不了十字段门，不需要日志提示
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
    // v0.5.60 miss 回包记录补 delegate 通道（v0.5.59 只挂了 completionHandler 包裹层，
    // 中枢实测 resp 全空：delegate 才是虾皮主流量通道，any=16 resp=0 实锤）。
    // 插在 pdp-only return 之前 → 任意端点都记；图片/CDN 类让位给 API 回包（非 shopee 域名满 12 条后不再记）
    if (gMissResp) {
      NSString *host = u.length ? ([NSURL URLWithString:u].host ?: @"") : @"";
      BOOL shpLike = (host.length == 0) || ([host containsString:@"shopee"]);
      @synchronized (gMissResp) {
        if (gMissResp.count < (shpLike ? 25 : 12)) {
          NSInteger st = 0;
          if (isTask) {
            id r = ((NSURLSessionTask *)requestLike).response;
            if ([r isKindOfClass:[NSHTTPURLResponse class]]) st = ((NSHTTPURLResponse *)r).statusCode;
          }
          NSString *pre = [[NSString alloc] initWithData:bufData encoding:NSUTF8StringEncoding] ?: @"";
          if (pre.length > 200) pre = [pre substringToIndex:200];
          [gMissResp addObject:@{ @"u": u ?: @"", @"c": @(st), @"len": @(bufData.length), @"p": pre }];
        }
      }
    }
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
    /* v0.5.38 统计持久化：重进 App 不清零，只有用户点「清零」才清（用户令） */
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    self.taken = (NSInteger)[d integerForKey:@"aha_stat_taken"];
    self.ok    = (NSInteger)[d integerForKey:@"aha_stat_ok"];
    /* v0.5.43 面板默认宽度 300 → 260（用户令：默认再窄一点）。
       老设备 cfg 里已经存着 300，只改默认值对它无效，必须迁移一次；
       只迁「没设过」和「正好等于旧默认 300」的 —— 用户自己拖过的宽度不覆盖。 */
    {
      double pw = [_cfg[@"panelW"] doubleValue];
      if (!_cfg[@"panelWVer"]) {
        if (pw < 1 || fabs(pw - 300) < 0.5) _cfg[@"panelW"] = @260;
        _cfg[@"panelWVer"] = @1;
        [self saveCfg];
      }
    }
  }
  return self;
}

/* v0.5.38 计数落盘（taken/ok 变化处调用；NSUserDefaults 每单一次写入，量小无压力） */
- (void)persistStats {
  NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
  [d setInteger:(NSInteger)self.taken forKey:@"aha_stat_taken"];
  [d setInteger:(NSInteger)self.ok    forKey:@"aha_stat_ok"];
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
  if (self.connecting) return @"● 连接中…";
  if (!self.connected) {
    NSString *u = [self.cfg[@"user"] stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceCharacterSet]];
    return (u.length == 0) ? @"● 请输入采集账号（⚙设置）" : @"● 未连接";
  }
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
- (void)resetCounters { self.taken = 0; self.ok = 0; self.taskLine = @""; [self persistStats]; }

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
    if (_logs.count > 400) [_logs removeObjectsInRange:NSMakeRange(0, _logs.count - 400)];   // v0.5.44 120→400：跑起来几轮就滚没了（用户报「日志莫名消失」）
  }
  @synchronized (self) { self.logVer++; }   // v0.5.44 渲染改跟版本号，不再比对全文
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
  /* v0.5.52 防御：地址填错（缺 https:// 等）URLWithString 返回 nil，
     拿 nil request 去 dataTask 会直接 NSInvalidArgumentException 崩给用户。
     改成把错误回传 done，让调用方走正常失败分支。 */
  NSURL *url = [NSURL URLWithString:[self.base stringByAppendingString:path ?: @""]];
  if (!url) {
    if (done) done(@{}, [NSError errorWithDomain:@"AHA" code:-2
        userInfo:@{ NSLocalizedDescriptionKey: @"中枢地址无效（检查 https:// 前缀）" }]);
    return;
  }
  NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
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
  /* v0.5.52 修复「没填账号一直卡在连接中」：startLoop 已把 connecting=YES，
     这里 early return 必须先复位，否则按钮永远停在「连接中…」 */
  if (u.length == 0) {
    self.connecting = NO;
    self.connected = NO; self.token = nil;
    ahaLog(@"e", @"请先填写采集账号（点⚙设置）");
    ahaRefreshNow();
    return;
  }
  self.taskLine = @"";
  ahaLog(@"i", [NSString stringWithFormat:@"[%@] 正在登录 %@ …", u, self.base]);
  [self api:@"/api/pool/login" method:@"POST"
      body:@{ @"name": u }
      done:^(NSDictionary *j, NSError *e) {
    dispatch_async(self.q, ^{
      self.connecting = NO;   // v0.5.43 登录已有结果（成或败），按钮不再锁在「连接中」
      if (j && [j[@"ok"] boolValue]) {
        self.token = j[@"token"];
        self.me = u;
        self.connected = YES;
        ahaLog(@"s", [NSString stringWithFormat:@"已连接 %@（敞口模式 · 池隔离）", self.me]);
        if (after) after();          // beginRun 内部会立即刷新按钮为「停止采集」
      } else {
        self.connected = NO; self.token = nil;
        ahaLog(@"e", [NSString stringWithFormat:@"登录失败：%@",
            j[@"error"] ?: (e.localizedDescription ?: @"网络不通")]);
        ahaRefreshNow();             // v0.5.43 失败立刻恢复按钮，别一直卡在「连接中」
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
  if (!self.connected) {
    /* v0.5.43 点击即反馈：先把按钮切成「连接中」再走登录，避免点了像没反应 */
    if (!self.connecting) { self.connecting = YES; ahaRefreshNow(); }
    [self connect:^{ [self beginRun]; }];
    return;
  }
  [self beginRun];
}
- (void)beginRun {
  dispatch_async(self.q, ^{
    if (self.running) return;
    self.connecting = NO;
    self.running = YES; self.resting = NO; self.risk = NO; self.failStreak = 0;
    ahaLog(@"s", @"领单循环已开始");
    ahaRefreshNow();    // v0.5.43 立即变「停止采集」，不再等 250ms 合并窗
    [self helloTick];   // v0.5.33 立即恢复有效窗口（不等 10s 心跳）
    [self takeOnce];
  });
}
- (void)stopLoop {
  dispatch_async(self.q, ^{
    if (!self.running) return;
    self.running = NO;
    self.resting = NO;   // v0.5.58 停止即清休息态（pending 的休息定时器到点 takeOnce 会因 !running 空转返回；lastRestTaken 防重复休息）
    self.connecting = NO;
    self.taskLine = @"已停止（进行中的单会做完）";
    ahaLog(@"w", @"循环已停止");
    ahaRefreshNow();    // v0.5.43 立即变「开始采集」
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
      [[AhaSharedSession()
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
    // v0.5.58 死循环修复：原条件 (taken%every)==0 && !resting 在休息结束时 resting 复位 NO →
    // takeOnce → takeOnceGo → taken%every 仍==0 → 立即再触发休息，无限循环。加 lastRestTaken
    // 标记：同一 taken 值只休一次，休息结束领了新单（taken 变化）后才开始下一轮计数。
    NSInteger every = [self num:@"restEvery" def:0];
    NSInteger rs = [self num:@"restSec" def:0];
    BOOL restOn = [self.cfg[@"restOn"] boolValue];
    if (restOn && every > 0 && rs > 0 && self.taken > 0 && (self.taken % every) == 0
        && !self.resting && self.taken != self.lastRestTaken) {
      self.resting = YES;
      self.lastRestTaken = self.taken;
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
        [self persistStats];   /* v0.5.38 重进不清零 */
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
    /* v0.5.44 截包赛跑（Ajie 思路：不等，抢时间）：
       等 app 自己的 get_pc 回包（0.5s 轮询），5 秒还没到就**并行**点火 Direct PDP 直连，
       谁先回用谁 —— 旧版要傻等满 15 秒才开始直连，页面加载一慢单笔任务烧 15~35 秒（用户报「卡很久」）。
       睡在后台队列，不堵 _q / 主线程。 */
    /* v0.5.49 提交对齐 Ajie：url/rawResponseUrl = 产出包体的真实来源 URL（0x372a0 实证），
       并把「来源通道」上报中枢留证（审核通过率按通道归因）。 */
    __block NSDictionary *capInfo = nil;
    /* v0.5.63 用户令对齐 Ajie：兜底直连整体删除（0x23b80 反汇编实证 Ajie 对没截到的单直接丢弃，
       从无任何直连/备用方案）。今日实战 48 单直连 0 胜=纯摆设，还留「启用备用方案」误导日志。
       「你尋找的商品已不存在」不受影响：noitem 报文信号 + 弹窗文案识别双通道照旧，
       命中即提交错误报文，聚星收了算成单（用户令：这类单必须提交，有钱）。 */
    __block NSString *pageNoItemHit = nil, *pageSample = nil;   // v0.5.56 主线程页面扫描结果回传
    /* v0.5.64 用户令节奏：进入商品后 5s 没截到包 → 重试（重进商品页），最多重试 2 次（共 3 轮×5s）；
       3 轮全空 = 任务回池 + 脚本暂停——八成是风控/验证墙，别再烧单。
       （v0.5.52 的 15s 单轮硬顶由此替代；noitem 双通道在每轮里照常生效，命中即提交不重试） */
    for (int attempt = 0; attempt < 3 && !capInfo; attempt++) {
      if (attempt > 0) {
        ahaLog(@"w", [NSString stringWithFormat:@"第 %ld 次重试：重进商品页再等 5 秒", (long)attempt]);
        ahaStep(@"任务:重试重进商品");
        dispatch_async(dispatch_get_main_queue(), ^{
          ahaOpenUniversalLink(shopId, itemId, taskUrl);
          ahaObserveBegin();   /* 观察窗归零重计本单 */
        });
      }
      for (int i = 0; i < 10 && !capInfo; i++) {
      [NSThread sleepForTimeInterval:0.5];
      // v0.5.53 noitem：等包期间收到错误回包信号 → 立即提交错误报文，
      // 不等 15s 超时（窗口端 v7.121 同款：立即放行提交，白等十几秒一单纯浪费）
      if (attempt == 0 && i == 0) [[AHACapture shared] clearNoItem];   // 只在首轮开局清残留；重试轮不丢已到的 noitem 信号
      if (!capInfo) {
        NSDictionary *ni = [[AHACapture shared] takeNoItemForShop:shopId item:itemId];
        if (ni) { capInfo = @{ @"body": ni[@"body"] ?: @"", @"url": ni[@"url"] ?: @"", @"noitem": @YES }; break; }
      }
      // v0.5.56 页面级「商品已不存在」识别（用户令：这类单直接提交，不点火直连）：
      // 导航后 app 没发 pdp 请求、页面直接显示「你尋找的商品已不存在」——扫 UI 文案命中即构造
      // 标准 error 报文提交（对齐窗口端 v7.121 错误报文原样提交=聚星算有效数据）。
      // 异步派主线程扫（UI API 必须在主线程），结果 __block 回传、下一轮读；直连门完全不动——
      // 正常商品没抓到包照常兜底。扫描本身不碰 capInfo，杜绝主线程/等包线程数据竞争。
      if (!capInfo && !pageNoItemHit) {
        dispatch_async(dispatch_get_main_queue(), ^{
          NSString *sample = nil;
          NSString *hit = ahaPageNoItemText(&sample);
          pageNoItemHit = hit;
          pageSample = sample;
        });
      }
      if (!capInfo && pageNoItemHit) {
        NSString *eb = [NSString stringWithFormat:
            @"{\"error\":266900002,\"data\":null,\"item_id\":%@,\"shop_id\":%@}", itemId, shopId];
        capInfo = @{ @"body": eb, @"url": pcUrl ?: @"", @"noitem": @YES };
        ahaLog(@"i", [NSString stringWithFormat:@"页面识别「%@」→ 直接提交错误报文（不点火直连）", pageNoItemHit]);
        // v0.5.61 弹窗主动关掉：识别命中就说明弹窗本体在屏上，点掉/关掉它，
        // 不挡下一单导航；弹窗下去=页面监控工作的肉眼实锤
        ahaDismissNoItemPopup();
        break;
      }
      NSDictionary *ci = [[AHACapture shared] bodyInfoForShop:shopId item:itemId];
      if ([(NSString *)ci[@"body"] length] > 100) { capInfo = ci; break; }
      }   // 内层 5s 轮结束（v0.5.64 外层 attempt）
    }
    NSDictionary *info = capInfo;   // v0.5.63 只剩截包一条道（Ajie 同款，无兜底赛跑）
    BOOL noItem = [[info objectForKey:@"noitem"] boolValue];   // v0.5.53 商品不存在单
    NSString *via = noItem ? @"noitem" : @"app截包";
    NSString *body = info[@"body"];
    __block NSDictionary *diDirect = nil;   // v0.5.66 直连终审结果（miss 存档用）
    if (!body) {
      /* v0.5.66 对齐 Ajie 0.1.3 Direct PDP（0x3d588/0x2bcfc/0x2fd04 反汇编）：
         Ajie 并非「无备用方案」——它是页面等 20s（waitingForPDP 看门狗）没等到 pdp 回包时，
         用 rememberRequestContextFromRequest 存下的 app 真实请求头，自己直连 get_pc 终审：
         回包要么是商品数据（提交）、要么 error 266900002（死商品→照样提交）、要么 90309999（墙→放弃）。
         今晚 20:30 后 15 单全灭的实锤：页面渲染完整但 pdp请求=0 全部请求=2~3（纯埋点）——
         app 压根不发数据请求（缓存渲染/反爬静默），截包永远空，只有直连能破局。
         用户令保留：3 轮重试 + 失败回池暂停（直连终审也拿不到才停）。 */
      ahaLog(@"i", @"3 轮没截到包，直连 get_pc 终审（Ajie 0.1.3 Direct PDP 同款）");
      ahaStep(@"任务:DirectPDP终审");
      diDirect = [self directFetchShop:shopId item:itemId taskUrl:taskUrl];
      if (diDirect && [(NSString *)diDirect[@"body"] length] > 100) {
        capInfo = diDirect; info = diDirect; body = diDirect[@"body"];
        noItem = [[diDirect objectForKey:@"noitem"] boolValue];
        via = noItem ? @"noitem" : @"DirectPDP";
        ahaLog(@"i", [NSString stringWithFormat:@"直连终审拿到%@报文，提交",
            noItem ? @"死商品" : @"商品"]);
      }
    }
    if (!body) {
      /* v0.5.64 用户令：3 轮重试全空 = 任务回池 + 脚本立即暂停（原先连续 2 次才停太宽容，
         一单烧 3 轮还不停 = 后面全是同款死页/验证墙，停了人工看） */
      ahaLog(@"e", @"3 轮重试全没截到包，任务回池并暂停（疑似风控/验证墙）");
      dispatch_async(self.q, ^{ [self riskStop]; });
      // v0.5.52 超时诊断（观察窗 v0.528 改静默后数据白丢——把关键三数打回来）：
      // pdp请求=0 且页面在列表 = 导航没真开/白板页；pdp请求>0 = 发了但回包没进门（另查）
      dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = ahaResolvedTopVC();
        ahaLog(@"w", [NSString stringWithFormat:
            @"没等到商品数据（页=%@ pdp请求=%ld 全部请求=%ld）",
            NSStringFromClass([vc class]), (long)gObsPdp, (long)gObsAny]);
        // v0.5.61 用户令：面板不再刷「页面文案样本」（样本只进中枢 miss.jsonl 存档，面板保持干净）
        // v0.5.53 死页诊断：窗内见过 error 回包但没能归属/不是 266900002 → 打来源，
        // 一测便知「商品已不存在」页到底打了哪个接口、回的什么错
        NSDictionary *pni = [[AHACapture shared] peekNoItem];
        if (pni) {
          NSURL *nu = [NSURL URLWithString:pni[@"url"]];
          ahaLog(@"w", [NSString stringWithFormat:@"窗内 error 回包来源：%@%@（未能归属本单）",
              nu.host ?: @"?", nu.path ?: @""]);
        }
        // v0.5.59 用户令（Ajie 没有的增强，0x23b80 反汇编实证它对没抓到的单直接丢弃）：
        // 没抓到的单也把全部证据传中枢存档 miss.jsonl，事后要分析随时拉。
        // 证据：pdp/全部请求数、页面 topVC、页面文案样本、窗内 error 回包（截 500 字）
        NSString *pniUrl = pni[@"url"] ?: @"";
        NSString *pniBody = [NSString stringWithFormat:@"%@", pni[@"body"] ?: @""];
        if (pniBody.length > 500) pniBody = [pniBody substringToIndex:500];
        NSString *ps = pageSample ?: @"";
        if (ps.length > 500) ps = [ps substringToIndex:500];
        [self api:@"/api/pool/miss" method:@"POST"
            body:@{ @"taskId": taskId, @"itemId": itemId ?: @"", @"shopId": shopId ?: @"",
                    @"taskUrl": taskUrl ?: @"", @"pid": pid ?: @"", @"acct": acct ?: @"",
                    @"pdp": @(gObsPdp), @"any": @(gObsAny), @"direct": @(diDirect != nil),   // v0.5.66 直连终审已尝试
                    @"topVC": NSStringFromClass([vc class]) ?: @"", @"page": ps,
                    @"errUrl": pniUrl, @"errBody": pniBody,
                    @"resp": (gMissResp ? [gMissResp copy] : @[]) }   // v0.5.59 窗口全部回包（URL+码+长度+前200字）
             done:nil];
        ahaObserveFlush();
      });
      /* v0.5.64 用户令：3 轮重试全空 → 任务回池 + 脚本暂停（开头已 riskStop，
         这里走正常回池上报，scheduleNext 不会再领新单——running 已 NO） */
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
      if (noItem) ahaLog(@"i", @"无有效商品数据（错误报文原样提交聚星）");   // v0.5.54 能提交的都提交
      ahaLog(@"i", @"提交中");   // v0.5.30 四状态：抢单成功/进入详情成功/提交中/提交成功
      // v0.5.49：真实来源 URL = 包体自带 > app 最近 pdp URL > 构造模板（Ajie url/rawResponseUrl 同款语义）
      NSString *realUrl = info[@"url"];
      if (realUrl.length == 0) realUrl = [[AHACapture shared] freshPdpURL];
      NSString *bAge = [NSString stringWithFormat:@"%@", info[@"age"] ?: @""];
      [self submit:taskId taskUrl:pcUrl result:body itemId:itemId acct:acct
           jxServer:jxServer token:subTok realUrl:realUrl via:via bAge:bAge honeypot:noItem];
    });
  });
}

// —— Direct PDP：重放 app 上下文调商品接口（Ajie 的核心兜底）——
// v0.5.24：优先重放 app 刚发出的真实 pdp/get URL（get_pc 已是老端点，SGW 直接 418）；
// 90 秒内 app 发过 pdp 请求才有 fresh URL，否则回退 get_pc 模板
// v0.5.49：返回 @{body,url}（url=本次直连真实使用的 URL，提交报文 url/rawResponseUrl 用它）
// v0.5.50 = Ajie 0x2729c/0x27790/0x2ed9c 三处对齐：
//   ①候选表按 Ajie 顺序（app 真实 URL → 任务 URL → get_pc 模板 → get 模板），只收含 /api/v4/pdp/ 的
//   ②每个候选先改写 query 的 item_id/itemid/itemids 与 shop_id/shopid 为「当前任务」的值——
//     不改写时请求打的是上一个商品，回包 item 不符 → 十字段门/归属校验过不去，本次直连白跑
//   ③逐个候选尝试，2xx 才算拿到；遇验证墙立即停（不再打后续候选，避免风控升级）
// v0.5.50 = Ajie 0x30a44 同款：回包 item/shop 必须与当前任务一致（防跨商品串包）
static BOOL ahaPdpBodyOwned(NSString *body, NSString *itemId, NSString *shopId) {
  if (itemId.length == 0) return YES;
  NSData *d = [body dataUsingEncoding:NSUTF8StringEncoding];
  id o = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
  if (![o isKindOfClass:[NSDictionary class]]) return NO;
  id data = o[@"data"];
  if (![data isKindOfClass:[NSDictionary class]]) return NO;
  id it = data[@"item"];
  if (![it isKindOfClass:[NSDictionary class]]) {
    id idd = data[@"item_data"];
    it = [idd isKindOfClass:[NSDictionary class]] ? idd[@"item"] : nil;
  }
  if (![it isKindOfClass:[NSDictionary class]]) return NO;
  NSString *iid = [NSString stringWithFormat:@"%@", it[@"item_id"] ?: it[@"itemid"] ?: @""];
  NSString *sid = [NSString stringWithFormat:@"%@", it[@"shop_id"] ?: it[@"shopid"] ?: @""];
  if (![iid isEqualToString:itemId]) return NO;
  if (shopId.length && sid.length && ![sid isEqualToString:shopId]) return NO;
  return YES;
}

static NSString *ahaRewritePdpURL(NSString *url, NSString *itemId, NSString *shopId) {
  if (url.length == 0) return url;
  NSURLComponents *c = [NSURLComponents componentsWithString:url];
  if (!c) return url;
  NSMutableArray<NSURLQueryItem *> *qs = [NSMutableArray array];
  BOOL hasItem = NO, hasShop = NO;
  for (NSURLQueryItem *q in (c.queryItems ?: @[])) {
    NSString *n = q.name.lowercaseString ?: @"";
    NSString *v = q.value;
    if ([n isEqualToString:@"item_id"] || [n isEqualToString:@"itemid"] || [n isEqualToString:@"itemids"]) {
      if (itemId.length) v = itemId;
      hasItem = YES;
    } else if ([n isEqualToString:@"shop_id"] || [n isEqualToString:@"shopid"]) {
      if (shopId.length) v = shopId;
      hasShop = YES;
    }
    [qs addObject:[NSURLQueryItem queryItemWithName:q.name value:v]];
  }
  if (!hasItem && itemId.length) [qs addObject:[NSURLQueryItem queryItemWithName:@"item_id" value:itemId]];
  if (!hasShop && shopId.length) [qs addObject:[NSURLQueryItem queryItemWithName:@"shop_id" value:shopId]];
  c.queryItems = qs;
  return c.URL.absoluteString ?: url;
}

static NSArray<NSString *> *ahaPdpCandidates(NSString *taskUrl, NSString *itemId, NSString *shopId) {
  NSMutableArray *raw = [NSMutableArray array];
  NSArray *seed = @[ [[AHACapture shared] freshPdpURL] ?: @"",
                     taskUrl ?: @"",
                     [NSString stringWithFormat:kGetPcTpl, itemId, shopId],
                     [NSString stringWithFormat:kGetTpl, itemId, shopId] ];
  for (NSString *u in seed) {
    if (u.length == 0) continue;
    if ([u rangeOfString:kPdpMark].location == NSNotFound) continue;   // Ajie addDirectPDPURLCandidate 同款过滤
    if ([raw containsObject:u]) continue;                              // 去重
    [raw addObject:u];
  }
  NSMutableArray *out = [NSMutableArray arrayWithCapacity:raw.count];
  for (NSString *u in raw) [out addObject:ahaRewritePdpURL(u, itemId, shopId)];
  return out;
}

// v0.5.50 = Ajie applyShopeeContextToRequest(0x27e14) 黑名单：这些头永不转发
//（Hop-by-hop / 传输层头交给 NSURLSession，原样带上只会让网关起疑或冲突）
static BOOL ahaHeaderBlocked(NSString *k) {
  static NSSet *exact; static NSArray *prefix; static dispatch_once_t o;
  dispatch_once(&o, ^{
    exact = [NSSet setWithArray:@[ @"host", @"content-length", @"connection", @"proxy-connection",
        @"upgrade", @"te", @"trailer", @"transfer-encoding", @"accept-encoding",
        @"if-none-match", @"if-modified-since", @"if-range", @"range" ]];
    prefix = @[ @"proxy-" ];
  });
  NSString *low = k.lowercaseString ?: @"";
  if ([exact containsObject:low]) return YES;
  for (NSString *p in prefix) if ([low hasPrefix:p]) return YES;
  return NO;
}

// 单次直连；verify 置 YES = 撞验证墙（调用方停止后续候选）
static NSString *ahaDirectOnce(NSString *url, NSDictionary *ctx, NSTimeInterval sec, BOOL *verify) {
  NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]
                                                    cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                timeoutInterval:sec];
  req.HTTPMethod = @"GET";
  req.HTTPShouldHandleCookies = YES;   // Ajie 0x2f1bc 同款
  for (NSString *k in ctx) {
    if (ahaHeaderBlocked(k)) continue;
    [req setValue:ctx[k] forHTTPHeaderField:k];
  }
  __block NSString *out = nil;
  __block BOOL wall = NO;
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  [[AhaSharedSession()
   dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
    NSHTTPURLResponse *hr = [r isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)r : nil;
    if (!e && d) {
      if (hr.statusCode >= 200 && hr.statusCode < 300)
        out = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
      else
        ahaLog(@"w", [NSString stringWithFormat:@"直调失败 HTTP %ld", (long)hr.statusCode]);
    } else if (e) {
      ahaLog(@"w", [NSString stringWithFormat:@"直调网络错误：%@", e.localizedDescription]);
    }
    if (out.length) {
      NSString *low = out.lowercaseString;
      if ([out rangeOfString:@"90309999"].location != NSNotFound ||
          [low rangeOfString:@"verify"].location != NSNotFound ||
          [low rangeOfString:@"captcha"].location != NSNotFound) {
        wall = YES; out = nil;
        ahaLog(@"w", @"直连回包=验证墙，停止重试");
      } else if ([out rangeOfString:@"266900002"].location != NSNotFound) {
        out = nil;   // Ajie：无数据，换下一个候选
      }
    }
    dispatch_semaphore_signal(sem);
  }] resume];
  dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)((sec + 2) * NSEC_PER_SEC)));
  if (verify) *verify = wall;
  return out;
}

- (NSDictionary *)directFetchShop:(NSString *)shopId item:(NSString *)itemId taskUrl:(NSString *)taskUrl {
  NSDictionary *ctx = [[AHACapture shared] contextCopy];
  if (!ctx.count) return nil;
  NSArray *cands = ahaPdpCandidates(taskUrl, itemId ?: @"", shopId ?: @"");
  // 总预算 22s 封顶（多候选串行不能把「进详情」拖成分钟级；Ajie 单次 15s，这里同量级）
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:22];
  for (NSString *url in cands) {
    NSTimeInterval left = [deadline timeIntervalSinceNow];
    if (left < 2) break;
    BOOL wall = NO;
    NSString *out = ahaDirectOnce(url, ctx, MIN(15.0, left), &wall);
    if (wall) break;   // 90309999 验证墙：直连环境下也被墙，别再烧候选
    // v0.5.66 对齐 Ajie 0.1.3（0x30644 判定 + 0x2fd04 提交块反汇编）：直连回包含
    // 非零 error（266900002 等）= 死商品信号，原样错误报文提交（Ajie 死商品也走提交块）；
    // 90309999 例外（上面 wall 已拦）。真实商品数据仍走 owned+valid 质量门。
    NSDictionary *ni = ahaNoItemFromBody(out, url);
    if (ni && [(NSString *)ni[@"body"] length] > 100)
      return @{ @"body": ni[@"body"], @"url": url, @"noitem": @YES };
    if (out.length > 100 && ahaPdpBodyOwned(out, itemId, shopId) && ahaPdpBodyValid(out))
      return @{ @"body": out, @"url": url, @"direct": @YES };
  }
  return nil;
}

// —— v0.5.32 第二刀：Ajie 设备号同款——稳定 device_id（UserDefaults 持久化），
// device_id 与 fingerprint_key 共用同一值（Ajie 0x34f38~0x34fd8 两次取 deviceID 的实测结构）
// v0.5.41 手机直连已删（全部走中枢代交），device_id 改由中枢统一生成下发；
// 本机持久设备号保留备用（__attribute__((unused)) 防 -Werror）
__attribute__((unused)) static NSString *ahaDeviceID(void) {
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
__attribute__((unused)) static NSString *ahaNewUuid(void) { return [[NSUUID UUID] UUIDString]; }

// —— v0.5.41 提交：全部走中枢代交（用户拍板：不要手机直连兜底）——
// 聚星 task/submit/v2 由中枢调用并判定回包；手机只显示中枢回传的成败。
// 中枢记账（bump submitted / acctDay / winStats）也在同一处，账本唯一不再有双路径分歧。
- (void)submit:(NSString *)taskId taskUrl:(NSString *)taskUrl result:(NSString *)result
        itemId:(NSString *)itemId acct:(NSString *)acct
      jxServer:(NSString *)jxServer token:(NSString *)token
        realUrl:(NSString *)realUrl via:(NSString *)via bAge:(NSString *)bAge
       honeypot:(BOOL)honeypot {
  (void)jxServer; (void)token;   // 领单下发字段保留在签名里（调用点不动），提交一律走中枢
  [self hubSubmit:taskId taskUrl:taskUrl result:result itemId:itemId acct:acct realUrl:realUrl via:via bAge:bAge honeypot:honeypot];
}

- (void)hubSubmit:(NSString *)taskId taskUrl:(NSString *)taskUrl result:(NSString *)result
           itemId:(NSString *)itemId acct:(NSString *)acct
           realUrl:(NSString *)realUrl via:(NSString *)via bAge:(NSString *)bAge
          honeypot:(BOOL)honeypot {
  [self api:@"/api/pool/submit" method:@"POST"
      body:@{ @"taskId": taskId, @"url": taskUrl, @"result": result,
              @"realUrl": realUrl ?: @"", @"via": via ?: @"",   // v0.5.49 真实来源URL + 通道（中枢对齐 Ajie 报文用）
              @"bAge": bAge ?: @"",                             // v0.5.52 包龄秒数（审核通过率按包新鲜度归因用）
              @"honeypot": @(honeypot),                         // v0.5.53 商品不存在单：中枢成单+蜜罐计数+死商品缓存（v7.134 同款）
              @"itemId": itemId ?: @"", @"acct": acct ?: @"",
              @"profileId": self.cfg[@"pid"] ?: @"" }
      done:^(NSDictionary *j, NSError *e) {
    dispatch_async(self.q, ^{
      if (j && [j[@"ok"] boolValue]) [self markOk:taskId via:@"中枢代交" resp:@""];
      else {
        // v0.5.41 失败原因直接用中枢回传的聚星判定（data.code/msg），手机不再自己判
        NSString *why = j[@"error"] ?: (e.localizedDescription ?: @"未知");
        ahaLog(@"e", [NSString stringWithFormat:@"提交失败：%@", why]);
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
  [self persistStats];   /* v0.5.38 重进不清零 */
  self.taskLine = @"";
  (void)taskId; (void)via; (void)resp;   // v0.5.30 精简：成功只留一行计数，回包原文不再进面板
  ahaLog(@"s", [NSString stringWithFormat:@"提交成功 %ld", (long)self.ok]);
  ahaRefreshUI();
  // v0.5.41 全走中枢代交：中枢 /api/pool/submit 自己记账，手机无需再发 ok 回执
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
@property(nonatomic, strong) UIView *riskBanner;   // v0.5.36 风控醒目横幅（Ajie 同款：红色闪烁条）
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

  CGFloat w = [gPool.cfg[@"panelW"] doubleValue] ?: 260;
  CGFloat h = [gPool.cfg[@"panelH"] doubleValue] ?: 420;
  if (w < 240 || w > scr.size.width) w = 260;   // v0.5.43 默认宽度 300→260，最小可拖到 240
  if (h < 420 || h > scr.size.height) h = 420;  // v0.5.44 面板最矮 420：老配置里存的 330 会让日志区被挤没（默认 380 也升到 420）
  CGFloat x = [gPool.cfg[@"panelX"] doubleValue] ?: 14;
  CGFloat y = [gPool.cfg[@"panelY"] doubleValue] ?: scr.size.height * 0.10;
  if (x < 0 || x + w > scr.size.width) x = 14;
  if (y < 0 || y + h > scr.size.height) y = scr.size.height * 0.10;

  AHAPanel *p = [[AHAPanel alloc] initWithFrame:CGRectMake(x, y, w, h)];
  /* v0.5.36b 0.62→0.75：用户反馈「有点太透明，稍微深点」——压住 Shopee 透底但仍保留半透明质感 */
  p.backgroundColor = AhaColor(16, 18, 24, 0.75);   // v0.5.28 半透明（Ajie 同款质感）
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
  self.ttl.userInteractionEnabled = YES;
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
  self.logBox.backgroundColor = AhaColor(0, 0, 0, 0.45);   /* v0.5.36b 0.35→0.45 同步微加深 */
  self.logBox.layer.cornerRadius = 8;
  self.logBox.clipsToBounds = YES;
  [p addSubview:self.logBox];
  self.logLabel = [[UILabel alloc] initWithFrame:CGRectZero];
  self.logLabel.numberOfLines = 0;
  self.logLabel.backgroundColor = [UIColor clearColor];
  self.logLabel.textColor = AhaColor(235, 235, 235, 0.92);
  self.logLabel.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
  [self.logBox addSubview:self.logLabel];

  // v0.5.36 风控横幅：header 正下方红条 + 闪烁，一进风控肉眼躲不开（Ajie 同款醒目度）
  UIView *rb = [[UIView alloc] initWithFrame:CGRectMake(0, 40, w, 26)];
  rb.backgroundColor = AhaColor(214, 40, 40, 0.96);
  rb.clipsToBounds = YES;
  UILabel *rl = [[UILabel alloc] initWithFrame:rb.bounds];
  rl.textAlignment = NSTextAlignmentCenter;
  rl.font = [UIFont boldSystemFontOfSize:13];
  rl.textColor = [UIColor whiteColor];
  rl.text = @"⚠ 风控！已自动停止，请手动过滑块/验证后再开始";
  [rb addSubview:rl];
  rb.hidden = YES;
  [p addSubview:rb];
  self.riskBanner = rb;

  // 右下角 resize 手柄
  self.rh = [[UILabel alloc] initWithFrame:CGRectMake(w - 20, h - 20, 20, 20)];
  self.rh.text = @"◢";
  self.rh.textColor = AhaColor(255, 255, 255, 0.35);
  self.rh.textAlignment = NSTextAlignmentCenter;
  self.rh.userInteractionEnabled = YES;
  [p addSubview:self.rh];
  [self.rh addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:p action:@selector(ahaResize:)]];

  // 收起小球（v0.5.36 加大：64x30→86x44，像 Ajie 一样一眼能看清「成 N」）
  UIView *mv = [[UIView alloc] initWithFrame:CGRectMake(scr.size.width - 100, scr.size.height * 0.16, 86, 44)];
  mv.backgroundColor = AhaColor(28, 120, 240, 0.95);
  mv.layer.cornerRadius = 22;
  mv.hidden = YES;
  self.mini = mv;
  self.miniInfo = [[UILabel alloc] initWithFrame:mv.bounds];
  self.miniInfo.textAlignment = NSTextAlignmentCenter;
  self.miniInfo.font = [UIFont boldSystemFontOfSize:16];
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
  /* v0.5.43 按下即反馈：手指一碰按钮就变暗、抬手恢复。
     以前点下去到按钮换文案要等 250ms 合并刷新，手感像「没点到」。 */
  [self.startBtn addTarget:self action:@selector(btnPress:) forControlEvents:UIControlEventTouchDown];
  [self.startBtn addTarget:self action:@selector(btnRelease:) forControlEvents:UIControlEventTouchUpInside
      | UIControlEventTouchUpOutside | UIControlEventTouchCancel | UIControlEventTouchDragExit];
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

  ahaLog(@"s", gPure ? @"AHA 已注入（纯净模式）" : @"AHA 已注入");   // v0.5.36：启动只报这一条（上次崩溃汇报已停用，面包屑仍记在本地，要查随时能翻）
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
    /* v0.5.52 保存前 trim + 去尾部斜杠：粘进来带空格/尾 / 会直接连不上（URL 拼接后路径错误） */
    NSString *sv = [a.textFields[0].text stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
    while ([sv hasSuffix:@"/"]) sv = [sv substringToIndex:sv.length - 1];
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
    self.mini.frame = CGRectMake(scr.size.width - 100, MIN(MAX(self.panel.frame.origin.y + 20, 60), scr.size.height - 70), 86, 44);
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
  if (self.riskBanner) self.riskBanner.frame = CGRectMake(0, 40, w, 26);   // v0.5.36 跟随面板宽度
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
  CGFloat lbh = h - y - 14;
  if (lbh < 56) lbh = 56;   /* v0.5.44 日志区保底 56px：休息行展开/面板偏矮时不再被挤没（日志「莫名消失」主犯，
                               旧版 330 高面板+休息行展开算出来是负数，日志框整个没了） */
  self.logBox.frame   = CGRectMake(12, y, w - 24, lbh);
  self.rh.frame       = CGRectMake(w - 20, h - 20, 20, 20);
}

- (void)btnPress:(UIButton *)b { b.alpha = 0.72; }
- (void)btnRelease:(UIButton *)b { b.alpha = 1.0; }

- (void)refresh {
  if (!self.panel) return;
  self.statusLabel.text = gPool.statusText;
  // v0.5.36 风控横幅：进风控显示+闪烁，解除即收（risk 在 beginRun/成功回包时清零）
  BOOL rk = gPool.risk;
  if (self.riskBanner && self.riskBanner.hidden == rk) {
    self.riskBanner.hidden = !rk;
    NSString *animKey = @"ahaRiskBlink";
    if (rk) {
      CABasicAnimation *blink = [CABasicAnimation animationWithKeyPath:@"opacity"];
      blink.fromValue = @1.0;
      blink.toValue = @0.35;
      blink.duration = 0.55;
      blink.autoreverses = YES;
      blink.repeatCount = HUGE_VALF;
      [self.riskBanner.layer removeAnimationForKey:animKey];
      [self.riskBanner.layer addAnimation:blink forKey:animKey];
    } else {
      [self.riskBanner.layer removeAnimationForKey:animKey];
    }
  }
  self.statusLabel.textColor = gPool.risk ? AhaColor(255, 90, 80, 1)
      : (gPool.running ? AhaColor(80, 220, 120, 1)
      : (gPool.connected ? AhaColor(120, 200, 255, 1) : AhaColor(255, 255, 255, 0.4)));
  self.counterLabel.text = gPool.counterText;
  self.taskLabel.text = gPool.taskText;
  // 大按钮 = 开始/停止 同一按钮
  if (gPool.connecting) {                 // v0.5.43 登录中：变灰锁住，防止连点开多个登录
    self.startBtn.enabled = NO;
    self.startBtn.alpha = 1.0;            // 按下态残留清理（禁用时收不到 touchUp）
    [self.startBtn setTitle:@"⏳ 连接中…" forState:UIControlStateNormal];
    self.startBtn.backgroundColor = AhaColor(110, 110, 118, 1);
  } else {
    self.startBtn.enabled = YES;
    if (gPool.running) {
      [self.startBtn setTitle:@"■ 停止采集" forState:UIControlStateNormal];
      self.startBtn.backgroundColor = AhaColor(200, 60, 56, 1);
    } else {
      [self.startBtn setTitle:@"▶ 开始采集" forState:UIControlStateNormal];
      self.startBtn.backgroundColor = AhaColor(34, 170, 90, 1);
    }
  }
  self.miniInfo.text = [NSString stringWithFormat:@"成 %ld", (long)gPool.ok];
  // v0.5.30 日志渲染：底部锚定 UILabel（不滚动、不设 contentOffset，修「日志消失」）
  // v0.5.39 丝滑：文本/框尺寸没变不重排版；拖拽中整个跳过（长日志 sizeThatFits 每 250ms
  // 白算一遍，正好叠在手指移动帧上 = 拖起来卡手），松手后下一轮自动补上
  // v0.5.44 渲染缓存从「全文比对」改成「版本号比对」：appendLog 每写一行 logVer++，
  // 拖拽/缩放期间跳过的更新靠版本号必补渲染，杜绝任何边界情况下日志停在旧内容
  // v0.5.45 渲染只排最末 48 行：底部锚定裁掉的旧行本来不可见，400 行全文 sizeThatFits
  // 每次刷新纯白算（高频日志时主线程可感）。视觉完全一致：永远只见最新几十行
  NSArray *lines = gPool.logLines;
  if (lines.count > 48) lines = [lines subarrayWithRange:NSMakeRange(lines.count - 48, 48)];
  NSString *txt = [lines componentsJoinedByString:@"\n"];
  CGFloat bw = self.logBox.bounds.size.width, bh = self.logBox.bounds.size.height;
  static NSUInteger sLastVer = 0; static BOOL sLastValid = NO;
  static CGFloat sLastBW = 0, sLastBH = 0;
  if (!gPanelDragging && bw > 1 && bh > 1
      && (!sLastValid || gPool.logVer != sLastVer || bw != sLastBW || bh != sLastBH)) {
    if (![txt isEqualToString:self.logLabel.text]) self.logLabel.text = txt;
    CGSize s = [self.logLabel sizeThatFits:CGSizeMake(bw - 8, CGFLOAT_MAX)];
    // 底边固定贴着日志框底部：内容多就向上溢出、被 logBox 裁掉最旧的行（永远看得到最新状态）
    self.logLabel.frame = CGRectMake(4, bh - s.height - 4, bw - 8, s.height);
    sLastVer = gPool.logVer; sLastBW = bw; sLastBH = bh; sLastValid = YES;
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

/* v0.5.43 立即刷新：只给「开始/停止/连接结果」这类状态切换用。
   日志仍走 250ms 合并（防乱跳），这里不合并——点了按钮必须马上看到变化。 */
static void ahaRefreshNow(void) {
  if (!gUI) return;
  if ([NSThread isMainThread]) { [gUI refresh]; return; }
  dispatch_async(dispatch_get_main_queue(), ^{ if (gUI) [gUI refresh]; });
}

#pragma mark - 面板容器实现（要在 AHAUI 接口之后才能调 layoutPanel）

@implementation AHAPanel
- (void)ahaPan:(UIPanGestureRecognizer *)g {
  static CGPoint origin;
  if (g.state == UIGestureRecognizerStateBegan) { origin = self.center; gPanelDragging = YES; }
  if (g.state == UIGestureRecognizerStateChanged) {
    CGPoint t = [g translationInView:self];
    self.center = CGPointMake(origin.x + t.x, origin.y + t.y);
  }
  if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
    gPanelDragging = NO;
    if (gPool) {
      gPool.cfg[@"panelX"] = @(self.frame.origin.x);
      gPool.cfg[@"panelY"] = @(self.frame.origin.y);
      [gPool saveCfg];
      ahaRefreshUI();   // 松手后立即补一次日志排版，不等 250ms 合并窗
    }
  }
}
- (void)ahaResize:(UIPanGestureRecognizer *)g {
  static CGFloat w0, h0;
  if (g.state == UIGestureRecognizerStateBegan) {
    w0 = self.frame.size.width; h0 = self.frame.size.height;
    gPanelDragging = YES;   // v0.5.44 缩放复用拖拽的丝滑机制：进行中跳过日志重排版
  }                          //（旧版缩放每帧 layoutPanel+日志 sizeThatFits 叠在手指帧上 = 卡手）
  if (g.state == UIGestureRecognizerStateChanged) {
    CGPoint t = [g translationInView:self];
    CGFloat scrW = [UIScreen mainScreen].bounds.size.width;
    CGFloat scrH = [UIScreen mainScreen].bounds.size.height;
    CGFloat w = MIN(MAX(w0 + t.x, 240), scrW - 20);   // v0.5.43 下限 280→240，可拖更窄
    CGFloat h = MIN(MAX(h0 + t.y, 420), scrH - 40);   // v0.5.44 下限 330→420：保住日志区高度
    self.frame = CGRectMake(self.frame.origin.x, self.frame.origin.y, w, h);
    if (gUI) [gUI layoutPanel];
  }
  if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
    gPanelDragging = NO;
    if (gUI) ahaRefreshNow();   // 松手立刻补排版，不用等 250ms 合并窗
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

// 启动时读出上次崩溃记录，写进面板日志（v0.5.36 停用：用户要求启动日志只显示「AHA 已注入」。
// 函数保留备用；面包屑 ahaStep 与崩溃落盘照常写本地，要排查随时把这里的调用接回去）
__attribute__((unused)) static void ahaReportLastCrash(void) {
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
  // v0.5.56 用户令：虚拟设备指纹功能整体下线（IDFV 中途变脸 → 服务端设备校验对不上 →
  // 首页数据不下发白屏/掉登，实机复现过）。钩子/种子/重置/解绑全套已删；
  // 这里一次性清掉历史残留键（种子/开关/账号标记），身份彻底回归真机原生。
  NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
  for (NSString *k in @[@"aha_fp_seed", @"aha_fp_acct", @"aha_fp_on"]) [defs removeObjectForKey:k];
  [defs synchronize];
  if (!gPure) {
    %init(gNetCapture);        // completionHandler 双变体（Ajie 0x1423c/0x1425c 1:1）
    %init(gNetJSON);           // NSJSONSerialization 元类钩（Ajie 0x14290 1:1）
    %init(gNetSession);        // sessionWithConfiguration 元类钩 → delegate 挂钩（Ajie 0x41d7c 同款）
  }
  gPool = [AHAPool shared];
  if (!gPure) ahaInstallCrashCatcher();   // v0.5.34：装回崩溃捕获器（诊断进详情闪退，根因下次启动面板直接显示）
  // v0.5.58 面板秒出（用户令，B 方案=Ajie 同款）：ctor 零延迟 async 建窗。原 dispatch_after 3s +
  // 主队列双重延迟实际 4~6s 才出现；Ajie ctor 反汇编实证 [SHPPluginController sharedInstance start]
  // 零延迟同步初始化。async 派发天然「主线程忙完才轮到我」，不阻塞启动，面板 ≈1s 内出现。
  dispatch_async(dispatch_get_main_queue(), ^{
    gUI = [AHAUI shared];
    [gUI boot];
    // v0.5.36：ahaReportLastCrash() 停用——启动日志只显示「AHA 已注入」
  });
}
