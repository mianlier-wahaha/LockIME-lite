// lockime-lite-daemon — 极简全局输入法锁定守护进程。
//
// 仅保留 LockIME 已验证的核心机制：
//   1) TIS 分布式通知驱动（零轮询抢焦）
//   2) 幂等 + 0.30s 抑制窗口，吸收自己 select 的回声
//   3) 每次强制切换挂 trailing reconcile（上限 3 次），兜底 CJKV 静默失败
//   4) 冲突退避：5s 滚动窗口内被改回 4 次 → 停战 10s，翻倍至 120s 上限
//   5) 密码框豁免：IsSecureEventInputEnabled() 期间放手，0.5s 轮询恢复
//   6) CJKV select 读回失败时 FocusNudge（3×3 透明浮窗抢 key）
//
// 依赖：仅 Foundation / AppKit / Carbon，无第三方库。
// 配置：~/Library/Application Support/LockIME-lite/config.json
// 状态：~/Library/Application Support/LockIME-lite/state.json（GUI 只读此文件）

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>

static NSString *const kReloadNote = @"com.lockime-lite.reload";
static NSString *const kStateNote  = @"com.lockime-lite.state";

static NSString *supportFile(NSString *name) {
    static NSString *base = nil;
    if (!base) {
        base = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/LockIME-lite"];
        [[NSFileManager defaultManager] createDirectoryAtPath:base
                                  withIntermediateDirectories:YES attributes:nil error:nil];
    }
    return [base stringByAppendingPathComponent:name];
}

#pragma mark - TIS helpers

static NSString *tis_currentID(void) {
    TISInputSourceRef s = TISCopyCurrentKeyboardInputSource();
    if (!s) return nil;
    CFStringRef sid = TISGetInputSourceProperty(s, kTISPropertyInputSourceID);
    NSString *r = sid ? (__bridge NSString *)sid : nil;
    CFRelease(s);
    return r;
}

static TISInputSourceRef tis_find(NSString *sid) {
    NSDictionary *filter = @{(__bridge NSString *)kTISPropertyInputSourceID: sid};
    CFArrayRef list = TISCreateInputSourceList((__bridge CFDictionaryRef)filter, false);
    TISInputSourceRef r = NULL;
    if (list && CFArrayGetCount(list) > 0) {
        r = (TISInputSourceRef)CFRetain(CFArrayGetValueAtIndex(list, 0));
    }
    if (list) CFRelease(list);
    return r;
}

static NSString *tis_name(TISInputSourceRef s) {
    if (!s) return nil;
    CFStringRef n = TISGetInputSourceProperty(s, kTISPropertyLocalizedName);
    return n ? (__bridge NSString *)n : nil;
}

static BOOL tis_isCJKV(TISInputSourceRef s) {
    CFArrayRef langs = TISGetInputSourceProperty(s, kTISPropertyInputSourceLanguages);
    if (!langs) return NO;
    for (id l in (__bridge NSArray *)langs) {
        if ([l hasPrefix:@"zh"] || [l hasPrefix:@"ja"] || [l hasPrefix:@"ko"]) return YES;
    }
    return NO;
}

// CJKV 输入法偶发静默失败（select 返回 noErr 但未生效）时的兜底：
// 用一个 3×3 透明浮窗抢一次 key window，促使 TIS 真正把切换落到前台上下文。
static void focusNudge(void) {
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(-10000, -10000, 3, 3)
                                              styleMask:NSWindowStyleMaskBorderless
                                                backing:NSBackingStoreBuffered defer:NO];
    w.alphaValue = 0;
    w.ignoresMouseEvents = YES;
    w.level = NSFloatingWindowLevel;
    [w makeKeyAndOrderFront:nil];
    [w orderOut:nil];
}

#pragma mark - LockDaemon

@interface LockDaemon : NSObject
@end

@implementation LockDaemon {
    // 配置（config.json 热重载）
    BOOL _enabled;
    NSString *_targetID;

    // 防自激
    double _settleUntil;          // 抑制窗口截止（uptime）
    NSInteger _reconcileRetries;  // 连续 reconcile 重试（上限 3）
    BOOL _recheckPending;

    // 冲突退避
    NSMutableArray<NSNumber *> *_conflictTimes; // 5s 滚动窗口内的改回时间戳
    double _backoffUntil;
    NSInteger _consecutivePauses;

    // 密码框豁免
    BOOL _secureWatchPending;

    // 状态
    NSInteger _activations;
    dispatch_source_t _configWatcher;
}

static const double kSuppress = 0.30;
static const NSInteger kMaxReconcile = 3;
static const double kConflictWindow = 5.0;
static const NSInteger kMaxConflict = 4;
static const double kBackoffBase = 10.0;
static const double kBackoffCap = 120.0;
static const double kSecurePoll = 0.5;

static double uptime(void) { return [NSProcessInfo processInfo].systemUptime; }

- (instancetype)init {
    if ((self = [super init])) {
        _conflictTimes = [NSMutableArray new];
    }
    return self;
}

- (void)start {
    // AppKit 离线初始化：只为 FocusNudge 的 NSWindow 可用，不建 Dock 图标。
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

    [self loadConfig];
    [self loadActivations];
    [self watchConfigFile];

    // 输入源变更 → 事件驱动，无轮询
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDistributedCenter(),
        (__bridge const void *)self,
        &LockDaemon_sourceChanged,
        kTISNotifySelectedKeyboardInputSourceChanged,
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);

    // GUI 写完配置后发的即时重载信号（vnode 监视之外的快速通道）
    [[NSDistributedNotificationCenter defaultCenter]
        addObserver:self selector:@selector(loadConfig) name:kReloadNote object:nil];

    NSLog(@"[lockime-lite] started. enabled=%d target=%@", _enabled, _targetID ?: @"(none)");
    if (_enabled && _targetID) [self enforce];
}

static void LockDaemon_sourceChanged(CFNotificationCenterRef center, void *observer,
                                     CFStringRef name, const void *object, CFDictionaryRef info) {
    LockDaemon *d = (__bridge LockDaemon *)observer;
    dispatch_async(dispatch_get_main_queue(), ^{ [d onSourceChanged]; });
}

- (void)onSourceChanged {
    [self writeState];   // 让 GUI 能实时看到当前输入法
    [self enforce];
}

#pragma mark 配置

- (void)loadConfig {
    NSData *data = [NSData dataWithContentsOfFile:supportFile(@"config.json")];
    BOOL enabled = NO;
    NSString *target = nil;
    if (data) {
        NSDictionary *cfg = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([cfg isKindOfClass:[NSDictionary class]]) {
            enabled = [cfg[@"enabled"] boolValue];
            id t = cfg[@"targetID"];
            if ([t isKindOfClass:[NSString class]] && [t length] > 0) target = t;
        }
    }
    BOOL targetChanged = !((_targetID == nil && target == nil) || [_targetID isEqualToString:target]);
    _enabled = enabled;
    _targetID = target;
    if (targetChanged) {
        _settleUntil = 0;
        _reconcileRetries = 0;
        [_conflictTimes removeAllObjects];
        _backoffUntil = 0;
        _consecutivePauses = 0;
    }
    NSLog(@"[lockime-lite] config loaded: enabled=%d target=%@", enabled, target ?: @"(none)");
    if (enabled && target) [self enforce];
}

- (void)loadActivations {
    NSDictionary *st = [NSDictionary dictionaryWithContentsOfFile:supportFile(@"state.plist")];
    _activations = [st[@"activations"] integerValue];
}

- (void)watchConfigFile {
    NSString *path = supportFile(@"config.json");
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [@{@"enabled": @NO} writeToFile:path atomically:YES];
    }
    int fd = open(path.fileSystemRepresentation, O_EVTONLY);
    if (fd < 0) return;
    __weak LockDaemon *weakSelf = self;
    _configWatcher = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, fd,
        DISPATCH_VNODE_WRITE | DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME,
        dispatch_get_main_queue());
    dispatch_source_set_event_handler(_configWatcher, ^{
        close(fd);
        [weakSelf loadConfig];
        [weakSelf watchConfigFile];   // 原子写会换 inode，需重新挂监视
    });
    dispatch_source_set_cancel_handler(_configWatcher, ^{});
    dispatch_resume(_configWatcher);
}

#pragma mark 状态输出（GUI 只读）

- (void)writeState {
    NSString *curID = tis_currentID();
    NSString *curName = nil;
    if (curID) {
        TISInputSourceRef s = tis_find(curID);
        if (s) { curName = tis_name(s); CFRelease(s); }
    }
    NSDictionary *st = @{
        @"enabled": @(_enabled),
        @"targetID": _targetID ?: @"",
        @"currentID": curID ?: @"",
        @"currentName": curName ?: @"",
        @"activations": @(_activations),
        @"backoffActive": @(uptime() < _backoffUntil),
        @"updatedAt": @([[NSDate date] timeIntervalSince1970]),
    };
    [st writeToFile:supportFile(@"state.plist") atomically:YES];
    [[NSDistributedNotificationCenter defaultCenter] postNotificationName:kStateNote object:nil];
}

#pragma mark 核心状态机

- (void)enforce {
    if (!_enabled || !_targetID) return;

    // 密码框豁免：安全输入期间 macOS 强制 ASCII，不与其对抗。
    if (IsSecureEventInputEnabled()) {
        if (!_secureWatchPending) {
            _secureWatchPending = YES;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSecurePoll * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                self->_secureWatchPending = NO;
                [self enforce];
            });
        }
        return;
    }

    double now = uptime();
    if (now < _backoffUntil) return;   // 冲突停战中

    NSString *cur = tis_currentID();
    if (!cur) return;
    if ([cur isEqualToString:_targetID]) {
        _reconcileRetries = 0;         // 锁定已满足，补充 reconcile 预算
        return;
    }
    if (now < _settleUntil) return;    // 自己的 select 还在落定窗口内

    // 确认漂移 → 准备修正。先判定是否在与第三方抢 IME。
    if ([self registerConflict]) {
        [self enterBackoff];
        return;
    }
    [self force];
}

- (void)force {
    TISInputSourceRef s = tis_find(_targetID);
    if (!s) { NSLog(@"[lockime-lite] target not found: %@", _targetID); return; }

    CFTypeRef cap = TISGetInputSourceProperty(s, kTISPropertyInputSourceIsSelectCapable);
    CFTypeRef enb = TISGetInputSourceProperty(s, kTISPropertyInputSourceIsEnabled);
    BOOL ok = cap && CFBooleanGetValue(cap) && enb && CFBooleanGetValue(enb);
    BOOL cjkv = tis_isCJKV(s);
    NSString *name = tis_name(s);

    if (ok && TISSelectInputSource(s) == noErr) {
        // CJKV 读回确认失败才 nudge（成功则不打扰前台）
        NSString *after = tis_currentID();
        if (cjkv && ![after isEqualToString:_targetID]) focusNudge();

        _activations++;
        _settleUntil = uptime() + kSuppress;
        NSLog(@"[lockime-lite] forced → %@ (total %ld)", name ?: _targetID, (long)_activations);
        [self writeState];
        [self scheduleReconcile];
    } else {
        NSLog(@"[lockime-lite] select failed: %@", _targetID);
    }
    CFRelease(s);
}

// trailing reconcile：select 静默失败 / 被立即改回时，窗口关闭后再查一次
- (void)scheduleReconcile {
    if (_recheckPending || _reconcileRetries >= kMaxReconcile) return;
    _reconcileRetries++;
    _recheckPending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((kSuppress + 0.02) * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        self->_recheckPending = NO;
        [self enforce];
    });
}

#pragma mark 冲突退避

- (BOOL)registerConflict {
    double now = uptime();
    NSIndexSet *stale = [_conflictTimes indexesOfObjectsPassingTest:
        ^BOOL(NSNumber *t, NSUInteger i, BOOL *stop) { return now - t.doubleValue > kConflictWindow; }];
    [_conflictTimes removeObjectsAtIndexes:stale];
    if (_conflictTimes.count >= kMaxConflict) return YES;
    [_conflictTimes addObject:@(now)];
    return NO;
}

- (void)enterBackoff {
    _consecutivePauses++;
    double interval = MIN(kBackoffBase * pow(2, _consecutivePauses - 1), kBackoffCap);
    _backoffUntil = uptime() + interval;
    [_conflictTimes removeAllObjects];
    NSLog(@"[lockime-lite] conflict detected — backing off %.0fs", interval);
    [self writeState];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((interval + 0.02) * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self enforce]; });
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        LockDaemon *daemon = [LockDaemon new];
        [daemon start];
        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
