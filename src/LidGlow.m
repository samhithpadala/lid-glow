#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dlfcn.h>
#import <math.h>

// CoreBrightness's logo fade controls are described in LogoLight's hardware research:
// https://github.com/Ark0N/LogoLight/blob/main/docs/corebrightnessd.md
@interface NSObject (Brightness)
- (id)copyPropertyForKey:(NSString *)key;
- (BOOL)setProperty:(id)value forKey:(NSString *)key;
- (NSArray<NSNumber *> *)copyKeyboardBacklightIDs;
- (BOOL)setProperty:(id)value withKey:(NSString *)key keyboardID:(NSNumber *)keyboardID;
@end

static NSString *const FadeDuration = @"LEPWMFactorFadeDuration";
static NSString *const LogicalState = @"DisplayLogicalState";
static const double HoldDuration = 1e9;

static NSString *const LogoCurve = @"LEPWMBrightnessNitsMapping";
static NSString *const SavedCurve = @"OriginalLogoBrightnessCurve";

static NSArray *IndependentCurve(NSArray *original) {
    if (![original isKindOfClass:NSArray.class] || original.count < 2) return nil;
    for (id point in original) {
        if (![point isKindOfClass:NSArray.class] || [point count] != 2 ||
            ![[point firstObject] isKindOfClass:NSNumber.class] ||
            ![[point lastObject] isKindOfClass:NSNumber.class]) return nil;
    }
    NSNumber *maximum = [original.lastObject lastObject];
    if (maximum.doubleValue <= 0) return nil;

    // Leave the dark endpoint intact. The OS still applies its ambient and power limits.
    NSMutableArray *curve = [NSMutableArray arrayWithObject:original.firstObject];
    for (NSUInteger i = 1; i < original.count; i++) {
        [curve addObject:@[[original[i] firstObject], maximum]];
    }
    return curve;
}

static BOOL RefreshBuiltInBrightness(void) {
    CGDirectDisplayID displays[16];
    uint32_t count = 0;
    if (CGGetOnlineDisplayList(16, displays, &count) != kCGErrorSuccess) return NO;

    static int (*readBrightness)(CGDirectDisplayID, float *);
    static int (*writeBrightness)(CGDirectDisplayID, float);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *service = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
                               RTLD_LAZY | RTLD_LOCAL);
        if (service) {
            readBrightness = dlsym(service, "DisplayServicesGetBrightness");
            writeBrightness = dlsym(service, "DisplayServicesSetBrightness");
        }
    });
    if (!readBrightness || !writeBrightness) return NO;

    for (uint32_t i = 0; i < count; i++) {
        if (!CGDisplayIsBuiltin(displays[i]) || !CGDisplayIsActive(displays[i])) continue;
        float level;
        // Re-submit the existing value so CoreBrightness recalculates the logo's output.
        return readBrightness(displays[i], &level) == 0 && writeBrightness(displays[i], level) == 0;
    }
    return NO;
}

@interface LogoControl : NSObject
@property (readonly) NSDictionary *reading;
@property (readonly) BOOL enabled;
@property (readonly) BOOL awake;
@property (readonly) BOOL moving;
@property (readonly) BOOL active;
- (BOOL)beginIndependentCurve;
- (BOOL)restoreCurve;
- (BOOL)aimForFactor:(double)target;
- (BOOL)updateFadeWithReading:(NSDictionary *)reading;
- (void)restoreWhileAwake:(BOOL)awake;
@end

@implementation LogoControl {
    id _client;
    id _keyboardClient;
    double _target;
    BOOL _rising;
    CFTimeInterval _deadline;
}

- (instancetype)init {
    self = [super init];
    if (self && dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY | RTLD_LOCAL)) {
        _client = [NSClassFromString(@"BrightnessSystemClient") new];
        _keyboardClient = [NSClassFromString(@"KeyboardBrightnessClient") new];
    }
    return self;
}

- (NSDictionary *)reading {
    if (![_client respondsToSelector:@selector(copyPropertyForKey:)]) return nil;
    id reading = [_client copyPropertyForKey:@"LEPWMState"];
    if (![reading isKindOfClass:NSDictionary.class] || ![reading[@"Factor"] isKindOfClass:NSNumber.class]) return nil;
    return reading;
}

- (BOOL)enabled {
    return [[_client copyPropertyForKey:@"LEBacklightMode"] intValue] != 0;
}

- (BOOL)awake {
    return ![[_client copyPropertyForKey:@"CBClamshellState"] boolValue];
}

- (BOOL)beginIndependentCurve {
    if (!self.reading || !self.enabled || !self.awake ||
        ![_client respondsToSelector:@selector(setProperty:forKey:)]) return NO;

    NSArray *original = [_client copyPropertyForKey:LogoCurve];
    NSArray *curve = IndependentCurve(original);
    if (!curve || [curve isEqual:original]) return NO;

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:original forKey:SavedCurve];
    if (![_client setProperty:curve forKey:LogoCurve] ||
        ![[_client copyPropertyForKey:LogoCurve] isEqual:curve] ||
        !RefreshBuiltInBrightness()) {
        [self restoreCurve];
        return NO;
    }
    return YES;
}

- (BOOL)restoreCurve {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSArray *original = [defaults arrayForKey:SavedCurve];
    if (!original) return YES;
    if (!self.reading) return NO;
    id current = [_client copyPropertyForKey:LogoCurve];
    if (!current) return NO;
    if ([current isEqual:IndependentCurve(original)]) {
        if (![_client setProperty:original forKey:LogoCurve] ||
            ![[_client copyPropertyForKey:LogoCurve] isEqual:original]) return NO;
        if (self.awake && [self.reading[@"DisplayNits"] doubleValue] > 0) {
            RefreshBuiltInBrightness();
        }
    }
    [defaults removeObjectForKey:SavedCurve];
    return YES;
}

- (BOOL)sendState:(BOOL)lit {
    if (![_client setProperty:lit ? @2 : @1 forKey:LogicalState]) return NO;
    if (!lit) {
        for (NSNumber *keyboard in [_keyboardClient copyKeyboardBacklightIDs]) {
            if (![_client setProperty:@2 withKey:LogicalState keyboardID:keyboard]) return NO;
        }
    }
    return YES;
}

- (BOOL)aimForFactor:(double)target {
    NSDictionary *state = self.reading;
    if (!state || !self.enabled || !self.awake ||
        ![_client respondsToSelector:@selector(setProperty:forKey:)] ||
        ![_keyboardClient respondsToSelector:@selector(copyKeyboardBacklightIDs)] ||
        ![_client respondsToSelector:@selector(setProperty:withKey:keyboardID:)] ||
        [_keyboardClient copyKeyboardBacklightIDs].count == 0) return NO;

    _active = YES;
    _target = fmax(0, fmin(1, target));
    _rising = _target >= [state[@"Factor"] doubleValue];
    if (_target == 0) _rising = NO;
    if (![_client setProperty:@(HoldDuration) forKey:FadeDuration] ||
        ![self sendState:!_rising] ||
        ![_client setProperty:@1.2 forKey:FadeDuration] ||
        ![self sendState:_rising]) {
        [self restoreWhileAwake:YES];
        return NO;
    }
    _moving = YES;
    _deadline = NSProcessInfo.processInfo.systemUptime + 2.6;
    return YES;
}

- (BOOL)updateFadeWithReading:(NSDictionary *)reading {
    if (!_moving) return YES;
    if (!reading || NSProcessInfo.processInfo.systemUptime > _deadline) return NO;

    double factor = [reading[@"Factor"] doubleValue];
    double tolerance = (_target == 0 || _target == 1) ? 0.002 : 0.008;
    if (_rising ? factor < _target - tolerance : factor > _target + tolerance) return YES;

    _moving = NO;
    if (_target == 0 || _target == 1) return [_client setProperty:@0 forKey:FadeDuration];
    return [_client setProperty:@(HoldDuration) forKey:FadeDuration] && [self sendState:!_rising];
}

- (void)restoreWhileAwake:(BOOL)awake {
    if (!_active) return;
    _moving = NO;
    [_client setProperty:@0.25 forKey:FadeDuration];
    if (awake) {
        [self sendState:NO];
        [self sendState:YES];
    } else {
        // Leave the lid and display power rules in charge when sleeping.
        [_client setProperty:@1 forKey:LogicalState];
    }
    [_client setProperty:@0 forKey:FadeDuration];
    _active = NO;
}
@end

static double AvailableLight(NSDictionary *state) {
    return [state[@"AppliedNits"] doubleValue] * [state[@"NitsMultiplier"] doubleValue];
}

#ifndef LID_GLOW_TEST
@interface AppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation AppDelegate {
    NSWindow *_window;
    NSSlider *_slider;
    NSTextField *_amount;
    NSTextField *_status;
    NSButton *_automatic;
    NSTimer *_timer;
    LogoControl *_logo;
    double _reference;
    double _lastTarget;
    double _lastAvailable;
    CFTimeInterval _nextCheck;
    CFTimeInterval _applyAfter;
    BOOL _manual;
    BOOL _sleeping;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    _logo = [LogoControl new];
    [_logo restoreCurve];
    _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 416, 252)
                                        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                  NSWindowStyleMaskMiniaturizable
                                          backing:NSBackingStoreBuffered defer:NO];
    _window.title = @"Lid Glow";
    _window.releasedWhenClosed = NO;

    NSTextField *heading = [NSTextField labelWithString:@"Apple logo brightness"];
    heading.font = [NSFont systemFontOfSize:24 weight:NSFontWeightSemibold];
    NSTextField *description = [NSTextField wrappingLabelWithString:
        @"Set the light on the back of your MacBook. The screen has its own brightness control."];
    description.textColor = NSColor.secondaryLabelColor;

    _amount = [NSTextField labelWithString:@"Automatic"];
    _amount.font = [NSFont monospacedDigitSystemFontOfSize:14 weight:NSFontWeightMedium];
    _amount.alignment = NSTextAlignmentRight;
    NSTextField *sliderLabel = [NSTextField labelWithString:@"Logo level"];
    sliderLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    _slider = [NSSlider sliderWithValue:100 minValue:0 maxValue:100 target:self action:@selector(sliderChanged:)];
    _slider.continuous = YES;
    [_slider setAccessibilityLabel:@"Apple logo brightness percentage"];

    _automatic = [NSButton buttonWithTitle:@"Use Manual" target:self action:@selector(changeMode:)];
    _automatic.enabled = NO;
    _status = [NSTextField wrappingLabelWithString:@""];
    _status.font = [NSFont systemFontOfSize:12];
    _status.textColor = NSColor.secondaryLabelColor;

    NSView *content = _window.contentView;
    NSDictionary *views = NSDictionaryOfVariableBindings(heading, description, sliderLabel, _amount, _slider, _status, _automatic);
    for (NSView *view in views.allValues) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:view];
    }
    for (NSString *format in @[
        @"H:|-24-[heading]-24-|", @"H:|-24-[description]-24-|",
        @"H:|-24-[sliderLabel]-(>=8)-[_amount]-24-|", @"H:|-24-[_slider]-24-|",
        @"H:|-24-[_status]-24-|", @"H:[_automatic]-24-|",
        @"V:|-23-[heading]-6-[description]-20-[sliderLabel]-6-[_slider]-10-[_status(>=28)]",
        @"V:[_automatic]-19-|"
    ]) {
        [NSLayoutConstraint activateConstraints:[NSLayoutConstraint constraintsWithVisualFormat:format options:0 metrics:nil views:views]];
    }
    [NSLayoutConstraint activateConstraints:@[
        [_amount.firstBaselineAnchor constraintEqualToAnchor:sliderLabel.firstBaselineAnchor],
        [_status.bottomAnchor constraintLessThanOrEqualToAnchor:_automatic.topAnchor constant:-8]
    ]];

    NSMenu *menu = [NSMenu new];
    NSMenuItem *appMenu = [NSMenuItem new];
    [menu addItem:appMenu];
    appMenu.submenu = [NSMenu new];
    [appMenu.submenu addItemWithTitle:@"Quit Lid Glow" action:@selector(terminate:) keyEquivalent:@"q"];
    NSApp.mainMenu = menu;

    NSNotificationCenter *workspace = NSWorkspace.sharedWorkspace.notificationCenter;
    [workspace addObserver:self selector:@selector(willSleep:) name:NSWorkspaceScreensDidSleepNotification object:nil];
    [workspace addObserver:self selector:@selector(willSleep:) name:NSWorkspaceWillSleepNotification object:nil];
    [workspace addObserver:self selector:@selector(didWake:) name:NSWorkspaceScreensDidWakeNotification object:nil];

    _lastTarget = NAN;
    _lastAvailable = NAN;
    _timer = [NSTimer timerWithTimeInterval:1.0 / 75 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
    [self tick:nil];
    [_window center];
    [_window makeKeyAndOrderFront:nil];
    [NSApp activate];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return YES; }

- (void)applicationWillTerminate:(NSNotification *)notification {
    [_timer invalidate];
    [_logo restoreWhileAwake:!_sleeping && _logo.awake];
    [_logo restoreCurve];
}

- (void)willSleep:(NSNotification *)notification {
    _sleeping = YES;
    [_logo restoreWhileAwake:NO];
    _lastTarget = NAN;
}

- (void)didWake:(NSNotification *)notification {
    _sleeping = NO;
    _lastTarget = NAN;
    _applyAfter = NSProcessInfo.processInfo.systemUptime + 0.45;
}

- (void)changeMode:(id)sender {
    if ([_automatic.title isEqualToString:@"Use Automatic"]) {
        [self useAutomatic:nil];
    } else {
        [self sliderChanged:_slider];
    }
}

- (void)sliderChanged:(NSSlider *)sender {
    if (!_manual) {
        NSDictionary *reading = _logo.reading;
        _reference = [reading[@"MaxNitsRestriction"] doubleValue] * [reading[@"NitsMultiplier"] doubleValue];
        if (_reference <= 0 || ![_logo beginIndependentCurve]) {
            [self showError];
            return;
        }
    }
    _manual = YES;
    _automatic.title = @"Use Automatic";
    _lastTarget = NAN;
    _automatic.enabled = YES;
    _amount.stringValue = [NSString stringWithFormat:@"%ld%%", lround(sender.doubleValue)];
    _applyAfter = NSProcessInfo.processInfo.systemUptime + 0.14;
}

- (void)useAutomatic:(id)sender {
    [_logo restoreWhileAwake:!_sleeping && _logo.awake];
    BOOL restored = [_logo restoreCurve];
    _manual = NO;
    _lastTarget = NAN;
    _lastAvailable = NAN;
    _slider.doubleValue = 100;
    _amount.stringValue = @"Automatic";
    _automatic.title = @"Use Manual";
    _nextCheck = 0;
    [self tick:nil];
    if (!restored) {
        _automatic.title = @"Use Automatic";
        _automatic.enabled = YES;
        _status.stringValue = @"Couldn’t restore the automatic curve. Click Use Automatic to retry.";
        _nextCheck = NSProcessInfo.processInfo.systemUptime + 3;
    }
}

- (void)showError {
    [self useAutomatic:nil];
    _status.stringValue = @"Couldn’t apply the logo brightness curve. Try again with the display awake.";
    _nextCheck = NSProcessInfo.processInfo.systemUptime + 3;
}

- (void)tick:(NSTimer *)timer {
    CFTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (_sleeping || (!_logo.moving && now < _nextCheck)) return;
    NSDictionary *reading = _logo.reading;
    if (_logo.moving) {
        if (![_logo updateFadeWithReading:reading]) [self showError];
        _nextCheck = now + 0.2;
        return;
    }
    _nextCheck = now + 0.30;
    if (!reading || !_logo.enabled) {
        _slider.enabled = NO;
        _automatic.enabled = _manual;
        _status.stringValue = reading ? @"The logo is turned off in macOS." :
                                         @"The logo light is unavailable. A MacBook Pro with PROLED XDR Display is required.";
        return;
    }

    double available = AvailableLight(reading);
    if (!_logo.awake || [reading[@"DisplayNits"] doubleValue] <= 0 || available <= 0) {
        [_logo restoreWhileAwake:NO];
        _lastTarget = NAN;
        _slider.enabled = NO;
        _automatic.enabled = _manual;
        _status.stringValue = @"Waiting for the built-in display to wake.";
        return;
    }

    _slider.enabled = YES;
    _automatic.enabled = YES;
    if (!_manual) {
        _status.stringValue = @"macOS is adjusting the logo automatically.";
        return;
    }
    double desired = _reference * round(_slider.doubleValue) / 100;
    double target = fmin(1, desired / available);
    if (now < _applyAfter) return;
    double error = fabs([reading[@"FinalNits"] doubleValue] - fmin(desired, available));
    BOOL changed = isnan(_lastTarget) || fabs(target - _lastTarget) > 0.014;
    BOOL outputMoved = error > fmax(3, available * 0.035);
    if (changed || (outputMoved && fabs(available - _lastAvailable) > 2)) {
        if (![_logo aimForFactor:target]) {
            [self showError];
            return;
        }
        _lastTarget = target;
        _lastAvailable = available;
    }
    _status.stringValue = desired > available + 2
        ? @"macOS is limiting the logo based on lighting or power conditions."
        : @"Lid Glow is holding your chosen level while the display is awake.";
}
@end

int main(void) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        AppDelegate *delegate = [AppDelegate new];
        app.delegate = delegate;
        [app run];
    }
}
#endif
