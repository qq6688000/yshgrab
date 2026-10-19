#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>

// ================= 全局状态 =================
static NSMutableArray<NSDictionary *> *gLinks;
static NSMutableSet<NSString *> *gSeen;
static UIWindow *gWindow;
static id gRoot;
static volatile BOOL gReady = NO;

// ================= 注入诊断 =================
// 运行时 dlopen AudioToolbox——不强链接，避免 dyld 加载失败导致 App 闪退
static void YSGBuzz(int n) {
    static void (*playSound)(int) = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox", RTLD_LAZY);
        if (h) playSound = (void(*)(int))dlsym(h, "AudioServicesPlaySystemSound");
    });
    if (!playSound) return;
    for (int i = 0; i < n; i++) {
        playSound(4095); // kSystemSoundID_Vibrate
        if (i < n - 1) [NSThread sleepForTimeInterval:0.35];
    }
}

static void YSGWriteLoaded(void) {
    NSString *stamp = [NSDate date].description;
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    NSString *line = [NSString stringWithFormat:@"YSHGrab 1.2.0 loaded in %@ at %@\n", bid, stamp];
    // 多路径写——总有一个能写进去
    NSArray *paths = @[
        @"/var/mobile/Documents/YSHGrab/loaded.txt",
        [[NSTemporaryDirectory() stringByAppendingPathComponent:@"yshgrab_loaded.txt"] stringByStandardizingPath],
    ];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *p in paths) {
        NSString *dir = [p stringByDeletingLastPathComponent];
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        [line writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    NSLog(@"YSHGrab 1.1.0 loaded in %@", bid);
}

static NSString *YSGFormat(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap); return s;
}

// ================= 注入到网页里的 JS =================
static NSString *YSGJS(void) {
    return
    @"(function(){"
    @"if(window.__ysg_installed)return;window.__ysg_installed=1;"
    @"var seen={};"
    // 宽松匹配——视频后缀或关键词
    @"function ok(u){if(!u||!/^https?:/i.test(u))return false;var s=u.toLowerCase();if(/\\.(m3u8|mp4|flv|ts|mpd|webm|mov|m4s|mkv|m4a|aac)(\\?|#|$)/i.test(s))return true;if(/m3u8|hls|dash|stream|playlist|manifest|segment|chunk|video|media|play|vod|mpd|ispayload/i.test(s))return true;return false;}"
    // 视频元素：不过滤直接报（blob: 也报）
    @"function repMedia(u,t){try{if(!u||seen[u])return;seen[u]=1;window.webkit.messageHandlers.ysgrab.postMessage({url:u,type:t||'media'});}catch(e){}}"
    // fetch/XHR 的 URL：宽松过滤
    @"function rep(u,t){try{if(!u||seen[u])return;if(!ok(u))return;seen[u]=1;window.webkit.messageHandlers.ysgrab.postMessage({url:u,type:t||''});}catch(e){}}"
    // 扫描 video/audio/iframe/embed
    @"function scan(){try{var vs=document.querySelectorAll('video,source,audio,iframe,embed');for(var i=0;i<vs.length;i++){var v=vs[i];var s=v.currentSrc||v.src||v.getAttribute('src')||'';if(s)repMedia(s,v.tagName);}}catch(e){}}"
    // Performance entries
    @"try{performance.getEntriesByType('resource').forEach(function(e){rep(e.name,'perf');});}catch(e){}"
    // fetch + response Content-Type 检查
    @"var of=window.fetch;if(of){window.fetch=function(){try{var a=arguments[0];var url=typeof a==='string'?a:(a&&a.url);if(url)rep(url,'fetch');}catch(e){}var p=of.apply(this,arguments);try{if(p&&p.then){p.then(function(r){try{var ct=(r.headers.get('content-type')||'').toLowerCase();if(/video|mpegurl|mp2t|mp4|x-mpegurl|octet-stream/i.test(ct)){var u=r.url||url;if(u&&!seen[u]){seen[u]=1;window.webkit.messageHandlers.ysgrab.postMessage({url:u,type:'fetch-video'});}}}}catch(e){}}).catch(function(){});}}catch(e){}return p;};}"
    // XHR + response Content-Type 检查
    @"var op=XMLHttpRequest.prototype.open;XMLHttpRequest.prototype.open=function(m,u){try{rep(u,'xhr');}catch(e){}var self=this;var xu=u;this.addEventListener('load',function(){try{var ct=(self.getResponseHeader('content-type')||'').toLowerCase();if(/video|mpegurl|mp2t|mp4|x-mpegurl|octet-stream/i.test(ct)){var u2=self.responseURL||xu;if(u2&&!seen[u2]){seen[u2]=1;window.webkit.messageHandlers.ysgrab.postMessage({url:u2,type:'xhr-video'});}}}catch(e){}});return op.apply(this,arguments);};"
    // HTMLMediaElement.src setter
    @"try{var d=Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype,'src');if(d&&d.set){Object.defineProperty(HTMLMediaElement.prototype,'src',{set:function(v){try{repMedia(v,'media-src');}catch(e){}d.set.call(this,v);},get:d.get});}}catch(e){}"
    // HTMLMediaElement.load
    @"try{var ol=HTMLMediaElement.prototype.load;HTMLMediaElement.prototype.load=function(){try{repMedia(this.currentSrc||this.src,'media-load');}catch(e){}return ol.apply(this,arguments);};}catch(e){}"
    // MutationObserver
    @"try{new MutationObserver(scan).observe(document.documentElement,{childList:true,subtree:true});}catch(e){}"
    @"setInterval(scan,1500);scan();"
    @"})();";
}

// ================= 数据 =================
static void YSGAddLink(NSString *url, NSString *type) {
    if (!url.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gLinks) { gLinks = [NSMutableArray new]; gSeen = [NSMutableSet new]; }
        if ([gSeen containsObject:url]) return;
        [gSeen addObject:url];
        [gLinks insertObject:@{@"url": url, @"type": type ?: @"", @"t": @([[NSDate date] timeIntervalSince1970])} atIndex:0];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"YSGUpdated" object:nil];
    });
}

// ================= WKWebView 追踪（定时器注入 JS） =================
static char kYSGTrackedKey;
static NSMutableArray *gTrackedWebViews = nil;

static void YSGTrackWebView(WKWebView *wv) {
    if (!wv) return;
    @try {
        if (objc_getAssociatedObject(wv, &kYSGTrackedKey)) return;
        objc_setAssociatedObject(wv, &kYSGTrackedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        @synchronized (gTrackedWebViews) {
            if (!gTrackedWebViews) gTrackedWebViews = [NSMutableArray new];
            [gTrackedWebViews addObject:wv];
        }
        // 立即注入一次
        dispatch_async(dispatch_get_main_queue(), ^{
            @try { [wv evaluateJavaScript:YSGJS() completionHandler:nil]; } @catch (NSException *e) {}
        });
    } @catch (NSException *e) {}
}

// 定时器：每 1.5 秒对所有已追踪的 WKWebView 注入 JS
static void YSGStartJSTimer(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            NSTimer *t = [NSTimer scheduledTimerWithTimeInterval:1.5 repeats:YES block:^(NSTimer *t) {
                @try {
                    NSArray *snap;
                    @synchronized (gTrackedWebViews) {
                        snap = [gTrackedWebViews copy];
                    }
                    for (WKWebView *wv in snap) {
                        @try {
                            [wv evaluateJavaScript:YSGJS() completionHandler:nil];
                        } @catch (NSException *e) {}
                    }
                } @catch (NSException *e) {}
            }];
            [[NSRunLoop currentRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
        });
    });
}

// ================= 悬浮球 =================
@interface YSGBall : UIView
@end
@implementation YSGBall
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.backgroundColor = [UIColor clearColor];
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.35;
        self.layer.shadowRadius = 6;
        self.layer.shadowOffset = CGSizeMake(0, 2);
        UILabel *l = [[UILabel alloc] initWithFrame:self.bounds];
        l.text = @"⇩";
        l.textColor = [UIColor whiteColor];
        l.font = [UIFont systemFontOfSize:26 weight:UIFontWeightBold];
        l.textAlignment = NSTextAlignmentCenter;
        l.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:l];
    }
    return self;
}
- (void)drawRect:(CGRect)r {
    CGContextRef c = UIGraphicsGetCurrentContext();
    CGRect b = CGRectInset(self.bounds, 2, 2);
    CGContextSetFillColorWithColor(c, [UIColor colorWithRed:0.09 green:0.55 blue:1.0 alpha:0.96].CGColor);
    CGContextFillEllipseInRect(c, b);
    CGContextSetStrokeColorWithColor(c, [UIColor colorWithWhite:1 alpha:0.45].CGColor);
    CGContextSetLineWidth(c, 1.2);
    CGContextStrokeEllipseInRect(c, b);
}
@end

// ================= 主界面 =================
@interface YSGRoot : UIViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) YSGBall *ball;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UILabel *hdrLabel;
@end

@implementation YSGRoot

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];

    CGFloat w = [UIScreen mainScreen].bounds.size.width;
    CGFloat h = [UIScreen mainScreen].bounds.size.height;
    CGFloat side = 52;
    NSArray *pos = [[NSUserDefaults standardUserDefaults] arrayForKey:@"YSGBallPos"];
    CGFloat x = pos.count == 2 ? [pos[0] doubleValue] : (w - side - 10);
    CGFloat y = pos.count == 2 ? [pos[1] doubleValue] : (h * 0.45);
    if (x < 4) x = 4; if (x > w - side - 4) x = w - side - 4;

    self.ball = [[YSGBall alloc] initWithFrame:CGRectMake(x, y, side, side)];
    self.ball.layer.cornerRadius = side / 2;
    [self.view addSubview:self.ball];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(togglePanel)];
    [self.ball addGestureRecognizer:tap];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
    [self.ball addGestureRecognizer:pan];
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onLongPress:)];
    lp.minimumPressDuration = 1.0;
    [self.ball addGestureRecognizer:lp];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refresh) name:@"YSGUpdated" object:nil];
}

- (void)onPan:(UIPanGestureRecognizer *)g {
    CGPoint p = [g translationInView:self.view];
    CGPoint c = self.ball.center;
    self.ball.center = CGPointMake(c.x + p.x, c.y + p.y);
    [g setTranslation:CGPointZero inView:self.view];
    if (g.state == UIGestureRecognizerStateEnded) {
        CGFloat w = self.view.bounds.size.width;
        CGFloat x = self.ball.center.x < w / 2 ? 36 : w - 36;
        [UIView animateWithDuration:0.2 animations:^{
            self.ball.center = CGPointMake(x, self.ball.center.y);
        }];
        [[NSUserDefaults standardUserDefaults] setObject:@[@(self.ball.center.x), @(self.ball.center.y)] forKey:@"YSGBallPos"];
    }
}

- (void)onLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    [gLinks removeAllObjects]; [gSeen removeAllObjects];
    [self refresh];
    [self flash:@"已清空"];
}

- (void)flash:(NSString *)s {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 140, 34)];
    l.center = self.view.center;
    l.text = s; l.textColor = [UIColor whiteColor];
    l.textAlignment = NSTextAlignmentCenter;
    l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.75];
    l.layer.cornerRadius = 10; l.clipsToBounds = YES;
    [self.view addSubview:l];
    [UIView animateWithDuration:1.2 animations:^{ l.alpha = 0; } completion:^(BOOL b){ [l removeFromSuperview]; }];
}

- (void)togglePanel {
    if (self.panel) { [self hidePanel]; } else { [self showPanel]; }
}

- (void)showPanel {
    CGFloat w = MIN(self.view.bounds.size.width - 32, 460);
    CGFloat h = MIN(self.view.bounds.size.height * 0.62, 560);
    UIView *p = [[UIView alloc] initWithFrame:CGRectMake((self.view.bounds.size.width - w) / 2,
                                                         (self.view.bounds.size.height - h) / 2, w, h)];
    p.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.97];
    p.layer.cornerRadius = 16; p.clipsToBounds = YES;
    p.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    self.panel = p;

    self.hdrLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 0, w - 130, 46)];
    self.hdrLabel.textColor = [UIColor whiteColor];
    self.hdrLabel.font = [UIFont boldSystemFontOfSize:15];
    [p addSubview:self.hdrLabel];

    UIButton *clear = [UIButton buttonWithType:UIButtonTypeSystem];
    clear.frame = CGRectMake(w - 118, 7, 44, 32);
    [clear setTitle:@"清空" forState:UIControlStateNormal];
    [clear addTarget:self action:@selector(clearAll) forControlEvents:UIControlEventTouchUpInside];
    [p addSubview:clear];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(w - 66, 7, 54, 32);
    [close setTitle:@"收起" forState:UIControlStateNormal];
    [close addTarget:self action:@selector(hidePanel) forControlEvents:UIControlEventTouchUpInside];
    [p addSubview:close];

    self.table = [[UITableView alloc] initWithFrame:CGRectMake(0, 46, w, h - 46) style:UITableViewStylePlain];
    self.table.backgroundColor = [UIColor clearColor];
    self.table.separatorColor = [UIColor colorWithWhite:1 alpha:0.08];
    self.table.delegate = self; self.table.dataSource = self;
    [p addSubview:self.table];

    p.transform = CGAffineTransformMakeScale(0.9, 0.9);
    p.alpha = 0;
    [self.view addSubview:p];
    [UIView animateWithDuration:0.18 animations:^{ p.transform = CGAffineTransformIdentity; p.alpha = 1; }];
    [self refresh];
}

- (void)hidePanel {
    UIView *p = self.panel; self.panel = nil; self.table = nil;
    [UIView animateWithDuration:0.15 animations:^{ p.alpha = 0; p.transform = CGAffineTransformMakeScale(0.9, 0.9); }
                     completion:^(BOOL b){ [p removeFromSuperview]; }];
}

- (void)clearAll {
    [gLinks removeAllObjects]; [gSeen removeAllObjects];
    [self refresh];
}

- (void)refresh {
    self.hdrLabel.text = YSGFormat(@"抓到 %lu 条视频链接", (unsigned long)gLinks.count);
    [self.table reloadData];
}

- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return gLinks.count; }

- (CGFloat)tableView:(UITableView *)t heightForRowAtIndexPath:(NSIndexPath *)i { return 62; }

- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)i {
    static NSString *cid = @"ysgcell";
    UITableViewCell *c = [t dequeueReusableCellWithIdentifier:cid];
    if (!c) {
        c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
        c.backgroundColor = [UIColor clearColor];
        c.textLabel.textColor = [UIColor whiteColor];
        c.textLabel.font = [UIFont systemFontOfSize:12];
        c.textLabel.numberOfLines = 2;
        c.detailTextLabel.textColor = [UIColor colorWithWhite:1 alpha:0.5];
        c.detailTextLabel.font = [UIFont systemFontOfSize:10];
        c.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    NSDictionary *d = gLinks[i.row];
    NSString *u = d[@"url"];
    NSString *kind = [u containsString:@".m3u8"] ? @"m3u8" : ([u containsString:@".mp4"] ? @"mp4" : d[@"type"]);
    c.textLabel.text = u;
    c.detailTextLabel.text = YSGFormat(@"%@ · %@", kind, u.length > 80 ? [u substringToIndex:80] : u);
    return c;
}

- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)i {
    NSString *u = gLinks[i.row][@"url"];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:nil message:u preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"下载" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
        [[NSClassFromString(@"YSGrab") class] performSelector:NSSelectorFromString(@"download:") withObject:u];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"复制链接" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
        [UIPasteboard generalPasteboard].string = u;
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"分享" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
        UIActivityViewController *v = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL URLWithString:u]] applicationActivities:nil];
        [self presentViewController:v animated:YES completion:nil];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if (ac.popoverPresentationController) {
        ac.popoverPresentationController.sourceView = self.panel;
        ac.popoverPresentationController.sourceRect = self.panel.bounds;
    }
    [self presentViewController:ac animated:YES completion:nil];
}
@end

// ================= 下载器 =================
@interface YSGrab : NSObject <WKScriptMessageHandler, NSURLSessionDataDelegate>
+ (instancetype)shared;
+ (void)download:(NSString *)url;
@end

static YSGrab *gGrab = nil;

@implementation YSGrab {
    UIView *_hud;
    UILabel *_hudLabel;
    UIProgressView *_hudBar;
    NSURLSession *_session;
}

+ (instancetype)shared {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gGrab = [YSGrab new]; });
    return gGrab;
}

- (void)userContentController:(WKUserContentController *)ucc didReceiveScriptMessage:(WKScriptMessage *)msg {
    if (![msg.name isEqualToString:@"ysgrab"]) return;
    id body = msg.body;
    if (![body isKindOfClass:[NSDictionary class]]) return;
    NSString *u = body[@"url"];
    if (![u isKindOfClass:[NSString class]]) return;
    // blob: 也保留（表示有视频在播，虽然不能直接下载）
    YSGAddLink(u, body[@"type"]);
}

// ---------- HUD ----------
- (void)showHUD:(NSString *)text progress:(BOOL)prog {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gWindow) return;
        if (!self->_hud) {
            UIView *h = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 220, 86)];
            h.center = gWindow.center;
            h.backgroundColor = [UIColor colorWithWhite:0 alpha:0.85];
            h.layer.cornerRadius = 14; h.clipsToBounds = YES;
            UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(10, 14, 200, 20)];
            l.textColor = [UIColor whiteColor];
            l.font = [UIFont systemFontOfSize:13];
            l.textAlignment = NSTextAlignmentCenter;
            [h addSubview:l];
            UIProgressView *p = [[UIProgressView alloc] initWithFrame:CGRectMake(20, 52, 180, 4)];
            [h addSubview:p];
            self->_hud = h; self->_hudLabel = l; self->_hudBar = p;
        }
        self->_hudLabel.text = text;
        self->_hudBar.hidden = !prog;
        self->_hudBar.progress = 0;
        [gWindow addSubview:self->_hud];
        self->_hud.alpha = 1;
    });
}

- (void)updateHUD:(NSString *)text progress:(float)p {
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_hudLabel.text = text;
        self->_hudBar.progress = p;
    });
}

- (void)hideHUD {
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.2 animations:^{ self->_hud.alpha = 0; }
                         completion:^(BOOL b){ [self->_hud removeFromSuperview]; }];
    });
}

- (void)alert:(NSString *)s {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = gWindow.rootViewController;
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"提示" message:s preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
        [vc presentViewController:a animated:YES completion:nil];
    });
}

// ---------- 分享 ----------
- (void)shareFile:(NSString *)path {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSURL *u = [NSURL fileURLWithPath:path];
        UIActivityViewController *vc = [[UIActivityViewController alloc] initWithActivityItems:@[u] applicationActivities:nil];
        UIViewController *top = gWindow.rootViewController;
        while (top.presentedViewController) top = top.presentedViewController;
        [top presentViewController:vc animated:YES completion:nil];
    });
}

// ---------- 入口 ----------
+ (void)download:(NSString *)url {
    YSGrab *g = [YSGrab shared];
    if ([url containsString:@".m3u8"] || [url containsString:@"m3u8"]) {
        [g downloadM3U8:url];
    } else if ([url hasPrefix:@"http"]) {
        [g downloadDirect:url];
    } else {
        [g alert:@"这个链接不能直接下载"];
    }
}

- (NSString *)tmpPath:(NSString *)ext {
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"yshgrab"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:YSGFormat(@"video_%ld.%@", (long)[[NSDate date] timeIntervalSince1970], ext)];
}

- (void)downloadDirect:(NSString *)url {
    [self showHUD:@"准备下载…" progress:YES];
    NSURLSessionDownloadTask *t = [[NSURLSession sharedSession] downloadTaskWithURL:[NSURL URLWithString:url]
        completionHandler:^(NSURL *loc, NSURLResponse *r, NSError *e) {
            if (!loc || e) { [self hideHUD]; [self alert:@"下载失败"]; return; }
            NSString *ext = [[url componentsSeparatedByString:@"?"][0] pathExtension];
            if (!ext.length) ext = @"mp4";
            NSString *dst = [self tmpPath:ext];
            [[NSFileManager defaultManager] moveItemAtURL:loc toURL:[NSURL fileURLWithPath:dst] error:nil];
            [self hideHUD];
            [self shareFile:dst];
        }];
    [t resume];
}

- (NSString *)resolve:(NSString *)u base:(NSURL *)base {
    u = [u stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSURL *n = [NSURL URLWithString:u relativeToURL:base];
    return n.absoluteString;
}

// ---------- m3u8 ----------
- (void)downloadM3U8:(NSString *)url {
    [self showHUD:@"解析播放列表…" progress:NO];
    NSURL *u = [NSURL URLWithString:url];
    [[[NSURLSession sharedSession] dataTaskWithURL:u completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (!data) { [self hideHUD]; [self alert:@"播放列表下载失败"]; return; }
        NSString *txt = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!txt) txt = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
        NSArray *lines = [txt componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];

        NSString *best = nil; double bestBW = -1;
        for (NSUInteger i = 0; i < lines.count; i++) {
            NSString *l = [lines[i] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (![l hasPrefix:@"#EXT-X-STREAM-INF"]) continue;
            double bw = 0;
            NSRange r = [l rangeOfString:@"BANDWIDTH="];
            if (r.location != NSNotFound) {
                NSString *tail = [l substringFromIndex:NSMaxRange(r)];
                NSCharacterSet *nd = [NSCharacterSet decimalDigitCharacterSet];
                NSRange dr = [tail rangeOfCharacterFromSet:nd];
                if (dr.location != NSNotFound) {
                    NSString *num = @"";
                    for (NSUInteger k = dr.location; k < tail.length; k++) {
                        unichar c = [tail characterAtIndex:k];
                        if (c < '0' || c > '9') break;
                        num = [num stringByAppendingFormat:@"%C", c];
                    }
                    bw = [num doubleValue];
                }
            }
            for (NSUInteger j = i + 1; j < lines.count; j++) {
                NSString *n = [lines[j] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                if (!n.length || [n hasPrefix:@"#"]) continue;
                if (bw >= bestBW) { bestBW = bw; best = n; }
                break;
            }
        }
        if (best.length) { [self downloadM3U8:[self resolve:best base:u]]; return; }
        if ([txt rangeOfString:@"#EXT-X-KEY"].location != NSNotFound) {
            [self hideHUD]; [self alert:@"这是加密 m3u8，暂不支持"]; return;
        }
        NSMutableArray *segs = [NSMutableArray new];
        for (NSString *l0 in lines) {
            NSString *l = [l0 stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (!l.length || [l hasPrefix:@"#"]) continue;
            [segs addObject:[self resolve:l base:u]];
        }
        if (!segs.count) { [self hideHUD]; [self alert:@"没解析到视频分片"]; return; }
        [self fetchSegments:segs index:0 file:[self tmpPath:@"ts"] total:segs.count];
    }] resume];
}

- (void)fetchSegments:(NSArray *)segs index:(NSUInteger)i file:(NSString *)file total:(NSUInteger)total {
    if (i >= segs.count) { [self hideHUD]; [self shareFile:file]; return; }
    [self updateHUD:YSGFormat(@"下载分片 %lu/%lu", (unsigned long)(i + 1), (unsigned long)total)
           progress:(float)i / (float)total];
    [[[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:segs[i]] completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        if (d.length) {
            if (![[NSFileManager defaultManager] fileExistsAtPath:file])
                [[NSFileManager defaultManager] createFileAtPath:file contents:nil attributes:nil];
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:file];
            [fh seekToEndOfFile];
            [fh writeData:d];
            [fh closeFile];
        }
        [self fetchSegments:segs index:i + 1 file:file total:total];
    }] resume];
}
@end

// ================= 窗口 =================
@interface YSGWindow : UIWindow
@end
@implementation YSGWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    if (v == self.rootViewController.view) return nil;
    return v;
}
@end

static void YSGSetupWindow(void) {
    if (gReady) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gReady) return;
        if (![UIApplication sharedApplication]) return;
        @try {
            // iOS 13+: 必须有 active windowScene 才能安全创建 UIWindow
            UIWindowScene *scene = nil;
            if (@available(iOS 13.0, *)) {
                for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
                    if ([s isKindOfClass:[UIWindowScene class]] && s.activationState == UISceneActivationStateForegroundActive) {
                        scene = (UIWindowScene *)s;
                        break;
                    }
                }
            }
            if (@available(iOS 13.0, *)) {
                if (!scene) return; // 等 App 完全启动后再试
            }

            YSGWindow *w = [[YSGWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
            w.windowLevel = UIWindowLevelAlert + 120;
            w.backgroundColor = [UIColor clearColor];
            w.rootViewController = [YSGRoot new];
            if (scene) w.windowScene = scene;
            w.hidden = NO;
            gWindow = w;
            gReady = YES;
            [YSGrab shared];
        } @catch (NSException *e) {
            NSLog(@"YSGSetupWindow crash: %@", e);
        }
    });
}

// 轮询确保悬浮球出现（无 WKWebView 的 App 也能出球）
static void YSGPollSetup(NSTimeInterval interval, int retries) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(interval * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (gReady) return;
        YSGSetupWindow();
        if (retries > 0) YSGPollSetup(interval, retries - 1);
    });
}


// ================= 原生 URL 过滤 =================
static BOOL YSGIsVideoURL(NSString *url) {
    if (!url || url.length < 8) return NO;
    NSString *lower = [url lowercaseString];
    static NSArray *exts = nil;
    static NSArray *kws = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        exts = @[@".m3u8", @".mp4", @".flv", @".ts", @".mpd", @".webm", @".mov", @".m4s", @".mkv"];
        kws = @[@"m3u8", @"hls", @"dash", @"stream", @"playlist", @"manifest", @"segment", @"chunk", @"video", @"media", @"vod", @"mpd"];
    });
    for (NSString *e in exts) if ([lower containsString:e]) return YES;
    for (NSString *k in kws) if ([lower containsString:k]) return YES;
    return NO;
}

// ================= Hook =================
%hook WKWebView

- (instancetype)initWithFrame:(CGRect)frame configuration:(WKWebViewConfiguration *)configuration {
    @try {
        WKUserContentController *ucc = configuration.userContentController;
        if (!ucc) {
            ucc = [[WKUserContentController alloc] init];
            configuration.userContentController = ucc;
        }
        static NSHashTable *seen = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ seen = [NSHashTable weakObjectsHashTable]; });
        if (![seen containsObject:ucc]) {
            [seen addObject:ucc];
            [ucc addUserScript:[[WKUserScript alloc] initWithSource:YSGJS()
                                                        injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                                     forMainFrameOnly:NO]];
            [ucc addScriptMessageHandler:[YSGrab shared] name:@"ysgrab"];
        }
    } @catch (NSException *e) {}
    YSGSetupWindow();
    WKWebView *result = %orig;
    YSGTrackWebView(result);
    return result;
}

// Storyboard / NSCoder 创建的 WKWebView（Safari 可能走这个入口）
- (instancetype)initWithCoder:(NSCoder *)coder {
    WKWebView *wv = %orig;
    @try {
        // 创建后取 configuration，注入 JS + messageHandler（configuration 是 copy，但 ucc 可改）
        WKWebViewConfiguration *cfg = wv.configuration;
        if (cfg) {
            WKUserContentController *ucc = cfg.userContentController;
            if (!ucc) { ucc = [WKUserContentController new]; cfg.userContentController = ucc; }
            static NSHashTable *seen2 = nil;
            static dispatch_once_t once2;
            dispatch_once(&once2, ^{ seen2 = [NSHashTable weakObjectsHashTable]; });
            if (![seen2 containsObject:ucc]) {
                [seen2 addObject:ucc];
                [ucc addUserScript:[[WKUserScript alloc] initWithSource:YSGJS()
                                                            injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                                         forMainFrameOnly:NO]];
                [ucc addScriptMessageHandler:[YSGrab shared] name:@"ysgrab"];
            }
        }
        // 注册导航回调：每次页面加载完成后用 evaluateJavaScript 兜底注入
        YSGTrackWebView(wv);
    } @catch (NSException *e) {}
    YSGSetupWindow();
    return wv;
}

// WKWebView 添加到窗口后——挂悬浮球 + 追踪
- (void)didMoveToWindow {
    %orig;
    WKWebView *wv = self;
    if (!wv.window) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        YSGSetupWindow();
        YSGTrackWebView(wv);
    });
}

%end
%group NSURLSessionGroup
%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url {
    @try { if (YSGIsVideoURL(url.absoluteString)) YSGAddLink(url.absoluteString, @"urlsession"); } @catch (NSException *e) {}
    return %orig;
}
- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))ch {
    @try { if (YSGIsVideoURL(url.absoluteString)) YSGAddLink(url.absoluteString, @"urlsession"); } @catch (NSException *e) {}
    return %orig;
}
- (NSURLSessionDownloadTask *)downloadTaskWithURL:(NSURL *)url {
    @try { if (YSGIsVideoURL(url.absoluteString)) YSGAddLink(url.absoluteString, @"urlsession-dl"); } @catch (NSException *e) {}
    return %orig;
}
%end
%end

// ================= AVURLAsset hook（抓 AVPlayer 原生播放） =================
%group AVGroup
%hook AVURLAsset
- (instancetype)initWithURL:(NSURL *)url options:(NSDictionary *)options {
    @try { YSGAddLink(url.absoluteString, @"AVURLAsset"); } @catch (NSException *e) {}
    return %orig;
}
%end
%end

// ================= FSPlayer hook（怪兽等 Flutter App） =================
%group FSPGroup
%hook FSPlayer
- (id)initWithContent:(id)content options:(id)options {
    @try {
        if ([content isKindOfClass:[NSString class]]) YSGAddLink(content, @"FSPlayer");
        else if ([content isKindOfClass:[NSURL class]]) YSGAddLink([(NSURL *)content absoluteString], @"FSPlayer");
    } @catch (NSException *e) {}
    return %orig;
}
- (id)initWithContentURL:(NSURL *)url withOptions:(id)options {
    @try { YSGAddLink(url.absoluteString, @"FSPlayer"); } @catch (NSException *e) {}
    return %orig;
}
- (NSURL *)contentURL {
    NSURL *u = %orig;
    @try { if (u) YSGAddLink(u.absoluteString, @"FSPlayer-contentURL"); } @catch (NSException *e) {}
    return u;
}
%end
%end

%ctor {
    @try {
        YSGrab *g = [YSGrab shared];
        (void)g;
        %init();
        %init(NSURLSessionGroup);
        if (NSClassFromString(@"AVURLAsset")) %init(AVGroup);
        if (NSClassFromString(@"FSPlayer")) %init(FSPGroup);
        YSGWriteLoaded();
        YSGBuzz(1); // 1 下振动 = 插件已注入
        YSGSetupWindow();
        YSGPollSetup(0.5, 20); // 0.5s 轮询 ×20 次（共 10s）确保出球
        YSGStartJSTimer(); // 启动定时器：每 1.5s 对所有 WKWebView 注入 JS
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *n){ YSGSetupWindow(); YSGPollSetup(0.5, 10); }];
        [[NSNotificationCenter defaultCenter] addObserverForName:@"UIApplicationDidBecomeKeyNotification"
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *n){ YSGSetupWindow(); }];
    } @catch (NSException *e) {
        NSLog(@"YSHGrab ctor crash: %@", e);
    }
}