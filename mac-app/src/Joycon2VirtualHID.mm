#import "../include/Joycon2VirtualHID.h"
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Foundation/Foundation.h>
#import <IOKit/hidsystem/ev_keymap.h>
#import <IOKit/hidsystem/IOLLEvent.h>

#include <algorithm>
#include <cmath>
#include <cctype>
#include <map>
#include <set>
#include <string>
#include <unistd.h>

// CommandLineTools-only setups may not ship the IOHIDUserDevice header, but the symbols exist at runtime.
typedef struct __IOHIDUserDevice* IOHIDUserDeviceRef;
extern "C" {
IOHIDUserDeviceRef IOHIDUserDeviceCreate(CFAllocatorRef allocator, CFDictionaryRef properties);
IOReturn IOHIDUserDeviceHandleReport(IOHIDUserDeviceRef device, const uint8_t* report, CFIndex reportLength);
}

static void JoyConLogThrottled(NSString* message) {
    static int counter = 0;
    counter++;
    if (counter <= 10 || (counter % 200) == 0) {
        NSLog(@"%@", message);
    }
}

static void PromptForAccessibilityIfNeeded(void) {
    static BOOL didPrompt = NO;
    if (didPrompt) {
        return;
    }
    didPrompt = YES;

    dispatch_async(dispatch_get_main_queue(), ^{
        NSAlert* alert = [[[NSAlert alloc] init] autorelease];
        alert.messageText = @"JoyCon2forMac needs Accessibility permission";
        alert.informativeText = @"Button/keyboard/mouse output will not work until you allow JoyCon2forMac in System Settings → Privacy & Security → Accessibility. After enabling, quit and relaunch the app.";
        [alert addButtonWithTitle:@"Open Accessibility Settings"];
        [alert addButtonWithTitle:@"OK"];
        NSModalResponse response = [alert runModal];
        if (response == NSAlertFirstButtonReturn) {
            NSURL* url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"];
            if (url) {
                [[NSWorkspace sharedWorkspace] openURL:url];
            }
        }
    });
}

typedef NS_ENUM(NSInteger, BindingActionKind) {
    BindingActionKindNone = 0,
    BindingActionKindKey,
    BindingActionKindMouseButton,
    BindingActionKindScroll,
    BindingActionKindGamepadButton,
    BindingActionKindGamepadDpad,
    BindingActionKindLaunchpad,
    BindingActionKindScreenshot,
    BindingActionKindOpenURL,
    BindingActionKindOpenApp,
    BindingActionKindRunShellCommand,
    BindingActionKindOpenFile,
    BindingActionKindMacro
};

typedef NS_ENUM(NSInteger, BindingMacroKind) {
    BindingMacroKindNone = 0,
    BindingMacroKindPOV,
    BindingMacroKindDoubleW,
    BindingMacroKindSpaceClick,
    BindingMacroKindShiftDelete
};

struct MouseConfig {
    double sensitivity = 0.35;
    double rightStickSensitivity = 0.35;
    double deadzone = 2.0;
    double smoothing = 0.6;
    double maxStep = 45.0;
    double jumpThreshold = 800.0;
    double calibrationSeconds = 1.0;
    BOOL invertX = NO;
    BOOL invertY = NO;
    int scrollStep = 3;
};

struct KeyboardConfig {
    double stickDeadzone = 0.35;
    std::string leftStickMode = "wasd";
};

struct BindingAction {
    BindingActionKind kind = BindingActionKindNone;
    BindingMacroKind macroKind = BindingMacroKindNone;
    CGKeyCode keyCode = 0;
    CGMouseButton mouseButton = kCGMouseButtonLeft;
    uint16_t gamepadButtonMask = 0;
    uint8_t gamepadDpadDirection = 8; // 0-7 = direction, 8 = neutral
    int scrollX = 0;
    int scrollY = 0;
    std::string url;
    std::string auxiliary;
    std::string description;
};

struct ButtonBinding {
    BindingAction pressAction;
    BindingAction tapAction;
};

struct RuntimeConfig {
    EmulationMode defaultMode = MODE_HYBRID;
    bool enableLeftJoyCon = true;
    MouseConfig mouse;
    KeyboardConfig keyboard;
    std::map<uint32_t, ButtonBinding> bindings;
    std::map<uint32_t, ButtonBinding> mouseBindings;
    std::map<uint32_t, ButtonBinding> keyboardBindings;
    std::map<uint32_t, ButtonBinding> hybridBindings;
    std::map<uint32_t, ButtonBinding> gamepadBindings;
    std::string loadedFrom;
};

struct DeviceState {
    uint32_t lastRawButtons = 0;
    uint32_t lastButtons = 0;
    bool mouseModePrimaryPressed = false;
    bool hybridMousePrimaryPressed = false;
    bool hasMouseSample = false;
    int16_t lastMouseX = 0;
    int16_t lastMouseY = 0;
    double smoothedDeltaX = 0.0;
    double smoothedDeltaY = 0.0;
    double driftBiasX = 0.0;
    double driftBiasY = 0.0;
    double smoothedRightStickX = 0.0;
    double smoothedRightStickY = 0.0;
    CFAbsoluteTime lastMouseIntentAt = 0.0;
    CFAbsoluteTime calibrationEndsAt = 0.0;
    CFAbsoluteTime screenshotPressedAt = 0.0;
    bool screenshotHoldTriggered = false;
    std::map<uint32_t, CFAbsoluteTime> buttonPressedAt;
    std::map<uint32_t, CFAbsoluteTime> lastTapActionAt;
    bool stickUp = false;
    bool stickDown = false;
    bool stickLeft = false;
    bool stickRight = false;
};

static std::string ToLower(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char ch) {
        return static_cast<char>(std::tolower(ch));
    });
    return value;
}

static std::string UpperNoSpaces(std::string value) {
    std::string normalized;
    normalized.reserve(value.size());
    for (unsigned char ch : value) {
        if (std::isspace(ch)) {
            continue;
        }
        normalized.push_back(static_cast<char>(std::toupper(ch)));
    }
    return normalized;
}

static std::string NormalizeKeyName(std::string value) {
    value = ToLower(value);
    std::replace(value.begin(), value.end(), '-', '_');
    std::replace(value.begin(), value.end(), ' ', '_');
    return value;
}

static double ClampDouble(double value, double minimum, double maximum) {
    if (value < minimum) {
        return minimum;
    }
    if (value > maximum) {
        return maximum;
    }
    return value;
}

static std::map<std::string, uint32_t> ButtonMaskMap() {
    return {
        {"ZL", 0x80000000}, {"L", 0x40000000}, {"SELECT", 0x00010000},
        {"LS", 0x00080000}, {"↓", 0x01000000}, {"UP", 0x02000000},
        {"RIGHT", 0x04000000}, {"LEFT", 0x08000000}, {"CAMERA", 0x00200000},
        {"SR(L)", 0x10000000}, {"SL(L)", 0x20000000}, {"HOME", 0x00100000},
        {"CHAT", 0x00400000}, {"START", 0x00020000}, {"SR(R)", 0x00001000},
        {"SL(R)", 0x00002000}, {"R", 0x00004000}, {"ZR", 0x00008000},
        {"RS", 0x00040000}, {"Y", 0x00000100}, {"X", 0x00000200},
        {"B", 0x00000400}, {"A", 0x00000800},
        {"DOWN", 0x01000000}, {"^", 0x02000000}, {"→", 0x04000000}, {"←", 0x08000000}
    };
}

static std::map<std::string, CGKeyCode> KeyCodeMap() {
    return {
        {"a", 0}, {"s", 1}, {"d", 2}, {"f", 3}, {"h", 4}, {"g", 5}, {"z", 6}, {"x", 7},
        {"c", 8}, {"v", 9}, {"b", 11}, {"q", 12}, {"w", 13}, {"e", 14}, {"r", 15},
        {"y", 16}, {"t", 17}, {"1", 18}, {"2", 19}, {"3", 20}, {"4", 21}, {"6", 22},
        {"5", 23}, {"equal", 24}, {"9", 25}, {"7", 26}, {"minus", 27}, {"8", 28},
        {"0", 29}, {"right_bracket", 30}, {"o", 31}, {"u", 32}, {"left_bracket", 33},
        {"i", 34}, {"p", 35}, {"return", 36}, {"enter", 36}, {"l", 37}, {"j", 38},
        {"quote", 39}, {"k", 40}, {"semicolon", 41}, {"backslash", 42}, {"comma", 43},
        {"slash", 44}, {"n", 45}, {"m", 46}, {"period", 47}, {"tab", 48}, {"space", 49},
        {"grave", 50}, {"delete", 51}, {"escape", 53}, {"esc", 53}, {"command", 55},
        {"left_command", 55}, {"shift", 56}, {"left_shift", 56}, {"caps_lock", 57},
        {"option", 58}, {"left_option", 58}, {"alt", 58}, {"control", 59},
        {"left_control", 59}, {"right_shift", 60}, {"right_option", 61},
        {"right_alt", 61}, {"right_control", 62}, {"left_arrow", 123},
        {"right_arrow", 124}, {"down_arrow", 125}, {"up_arrow", 126},
        {"f1", 122}, {"f2", 120}, {"f3", 99}, {"f4", 118}, {"f5", 96}
    };
}

static EmulationMode ModeFromString(NSString* value) {
    NSString* lower = [[value lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([lower isEqualToString:@"mouse"]) {
        return MODE_MOUSE;
    }
    if ([lower isEqualToString:@"keyboard"]) {
        return MODE_KEYBOARD;
    }
    if ([lower isEqualToString:@"gamepad"]) {
        return MODE_GAMEPAD;
    }
    return MODE_HYBRID;
}

static NSString* ModeName(EmulationMode mode) {
    switch (mode) {
        case MODE_MOUSE:
            return @"mouse";
        case MODE_KEYBOARD:
            return @"keyboard";
        case MODE_GAMEPAD:
            return @"gamepad";
        case MODE_HYBRID:
        default:
            return @"hybrid";
    }
}

static BindingAction ParseActionString(NSString* actionString, const RuntimeConfig& config) {
    BindingAction action;
    if (![actionString isKindOfClass:[NSString class]]) {
        return action;
    }

    NSString* trimmed = [actionString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) {
        return action;
    }

    NSRange colonRange = [trimmed rangeOfString:@":"];
    if (colonRange.location == NSNotFound) {
        return action;
    }

    NSString* category = [[trimmed substringToIndex:colonRange.location] lowercaseString];
    NSString* rawTarget = [trimmed substringFromIndex:colonRange.location + 1];
    std::string target = NormalizeKeyName([rawTarget UTF8String]);
    action.description = [trimmed UTF8String];

    if ([category isEqualToString:@"key"]) {
        auto keyCodes = KeyCodeMap();
        auto it = keyCodes.find(target);
        if (it != keyCodes.end()) {
            action.kind = BindingActionKindKey;
            action.keyCode = it->second;
        }
        return action;
    }

    if ([category isEqualToString:@"mouse"]) {
        if (target == "left") {
            action.kind = BindingActionKindMouseButton;
            action.mouseButton = kCGMouseButtonLeft;
        } else if (target == "right") {
            action.kind = BindingActionKindMouseButton;
            action.mouseButton = kCGMouseButtonRight;
        } else if (target == "middle" || target == "center") {
            action.kind = BindingActionKindMouseButton;
            action.mouseButton = kCGMouseButtonCenter;
        } else if (target == "scroll_up") {
            action.kind = BindingActionKindScroll;
            action.scrollY = config.mouse.scrollStep;
        } else if (target == "scroll_down") {
            action.kind = BindingActionKindScroll;
            action.scrollY = -config.mouse.scrollStep;
        } else if (target == "scroll_left") {
            action.kind = BindingActionKindScroll;
            action.scrollX = -config.mouse.scrollStep;
        } else if (target == "scroll_right") {
            action.kind = BindingActionKindScroll;
            action.scrollX = config.mouse.scrollStep;
        }
    }

    if ([category isEqualToString:@"gamepad"]) {
        if (target == "a") {
            action.kind = BindingActionKindGamepadButton;
            action.gamepadButtonMask = (1u << 0);
        } else if (target == "b") {
            action.kind = BindingActionKindGamepadButton;
            action.gamepadButtonMask = (1u << 1);
        } else if (target == "x") {
            action.kind = BindingActionKindGamepadButton;
            action.gamepadButtonMask = (1u << 2);
        } else if (target == "y") {
            action.kind = BindingActionKindGamepadButton;
            action.gamepadButtonMask = (1u << 3);
        } else if (target == "l1") {
            action.kind = BindingActionKindGamepadButton;
            action.gamepadButtonMask = (1u << 4);
        } else if (target == "r1") {
            action.kind = BindingActionKindGamepadButton;
            action.gamepadButtonMask = (1u << 5);
        } else if (target == "l2") {
            action.kind = BindingActionKindGamepadButton;
            action.gamepadButtonMask = (1u << 6);
        } else if (target == "r2") {
            action.kind = BindingActionKindGamepadButton;
            action.gamepadButtonMask = (1u << 7);
        } else if (target == "minus") {
            action.kind = BindingActionKindGamepadButton;
            action.gamepadButtonMask = (1u << 8);
        } else if (target == "plus") {
            action.kind = BindingActionKindGamepadButton;
            action.gamepadButtonMask = (1u << 9);
        } else if (target == "l3") {
            action.kind = BindingActionKindGamepadButton;
            action.gamepadButtonMask = (1u << 10);
        } else if (target == "r3") {
            action.kind = BindingActionKindGamepadButton;
            action.gamepadButtonMask = (1u << 11);
        } else if (target == "home") {
            action.kind = BindingActionKindGamepadButton;
            action.gamepadButtonMask = (1u << 12);
        } else if (target == "capture") {
            action.kind = BindingActionKindGamepadButton;
            action.gamepadButtonMask = (1u << 13);
        } else if (target == "dpad_up") {
            action.kind = BindingActionKindGamepadDpad;
            action.gamepadDpadDirection = 0;
        } else if (target == "dpad_down") {
            action.kind = BindingActionKindGamepadDpad;
            action.gamepadDpadDirection = 1;
        } else if (target == "dpad_left") {
            action.kind = BindingActionKindGamepadDpad;
            action.gamepadDpadDirection = 2;
        } else if (target == "dpad_right") {
            action.kind = BindingActionKindGamepadDpad;
            action.gamepadDpadDirection = 3;
        }
        return action;
    }

    if ([category isEqualToString:@"system"]) {
        if (target == "launchpad") {
            action.kind = BindingActionKindLaunchpad;
        } else if (target == "screenshot") {
            action.kind = BindingActionKindScreenshot;
        } else if (target == "discord") {
            action.kind = BindingActionKindOpenURL;
            action.url = "https://discord.com/app";
        } else if (target == "pov") {
            action.kind = BindingActionKindMacro;
            action.macroKind = BindingMacroKindPOV;
        } else if (target == "double_w") {
            action.kind = BindingActionKindMacro;
            action.macroKind = BindingMacroKindDoubleW;
        } else if (target == "space_click") {
            action.kind = BindingActionKindMacro;
            action.macroKind = BindingMacroKindSpaceClick;
        } else if (target == "shift_delete") {
            action.kind = BindingActionKindMacro;
            action.macroKind = BindingMacroKindShiftDelete;
        }
    }

    if ([category isEqualToString:@"app"]) {
        action.kind = BindingActionKindOpenApp;
        action.url = [rawTarget UTF8String];
        return action;
    }

    if ([category isEqualToString:@"shell"]) {
        action.kind = BindingActionKindRunShellCommand;
        action.url = [rawTarget UTF8String];
        return action;
    }

    if ([category isEqualToString:@"file"]) {
        action.kind = BindingActionKindOpenFile;
        action.url = [rawTarget UTF8String];
        return action;
    }

    if ([category isEqualToString:@"file_with"]) {
        action.kind = BindingActionKindOpenFile;
        NSArray<NSString*>* fileParts = [rawTarget componentsSeparatedByString:@"\t"];
        if (fileParts.count > 0) {
            action.url = [fileParts[0] UTF8String];
        }
        if (fileParts.count > 1) {
            action.auxiliary = [fileParts[1] UTF8String];
        }
        return action;
    }

    return action;
}

static ButtonBinding ParseBindingValue(id value, const RuntimeConfig& config) {
    ButtonBinding binding;
    if ([value isKindOfClass:[NSString class]]) {
        binding.pressAction = ParseActionString(value, config);
        return binding;
    }

    if (![value isKindOfClass:[NSDictionary class]]) {
        return binding;
    }

    NSDictionary* dictionary = (NSDictionary*)value;
    id pressValue = dictionary[@"press"] ?: dictionary[@"hold"];
    id tapValue = dictionary[@"tap"] ?: dictionary[@"click"];
    if ([pressValue isKindOfClass:[NSString class]]) {
        binding.pressAction = ParseActionString(pressValue, config);
    }
    if ([tapValue isKindOfClass:[NSString class]]) {
        binding.tapAction = ParseActionString(tapValue, config);
    }
    return binding;
}

static void LoadBindingsFromDictionary(NSDictionary* dictionary,
                                       std::map<uint32_t, ButtonBinding>& target,
                                       const RuntimeConfig& config,
                                       NSString* label) {
    if (![dictionary isKindOfClass:[NSDictionary class]]) {
        return;
    }

    target.clear();
    auto masks = ButtonMaskMap();
    for (NSString* rawButtonName in dictionary) {
        id actionValue = dictionary[rawButtonName];
        std::string buttonName = UpperNoSpaces([rawButtonName UTF8String]);
        auto maskIt = masks.find(buttonName);
        if (maskIt == masks.end()) {
            NSLog(@"Ignoring unknown button binding '%@' in %@", rawButtonName, label);
            continue;
        }

        ButtonBinding binding = ParseBindingValue(actionValue, config);
        if (binding.pressAction.kind == BindingActionKindNone && binding.tapAction.kind == BindingActionKindNone) {
            NSLog(@"Ignoring unsupported action '%@' for button '%@' in %@", actionValue, rawButtonName, label);
            continue;
        }

        target[maskIt->second] = binding;
    }
}

@interface Joycon2VirtualHID () {
@private
    RuntimeConfig _config;
    std::map<std::string, DeviceState> _deviceStates;
    NSTask *_screenRecordingTask;
    NSString *_screenRecordingPath;
    BOOL _leftMouseHeld;
    BOOL _rightMouseHeld;
    BOOL _middleMouseHeld;
    NSWindow *_capturePreviewWindow;
    NSTimer *_capturePreviewTimer;
    CGEventSourceRef _eventSource;
    BOOL _hasCursorPosition;
    CGPoint _cursorPosition;
    CFAbsoluteTime _lastDoubleWAt;
    CFAbsoluteTime _lastSpaceTapAt;
    IOHIDUserDeviceRef _gamepadDevice;
    uint16_t _gamepadButtons;
    bool _gamepadDpadUp;
    bool _gamepadDpadDown;
    bool _gamepadDpadLeft;
    bool _gamepadDpadRight;
    int8_t _gamepadLX;
    int8_t _gamepadLY;
    int8_t _gamepadRX;
    int8_t _gamepadRY;
}
- (void)setupKeyboardEventTap;
- (void)ensureAccessibilityPermission;
- (void)setupGamepadDeviceIfNeeded;
- (void)destroyGamepadDevice;
- (void)sendGamepadReport;
- (void)setGamepadButtonMask:(uint16_t)mask down:(BOOL)down;
- (void)setGamepadDpadDirection:(uint8_t)direction down:(BOOL)down;
- (void)updateGamepadAxesFromJoyconData:(NSDictionary*)joyconData deviceType:(const std::string&)deviceType;
- (void)loadConfig;
- (void)installDefaultBindings;
- (const ButtonBinding*)bindingForMask:(uint32_t)mask mode:(EmulationMode)mode;
- (void)switchToMode:(EmulationMode)mode;
- (void)releaseAllPressedInputs;
- (void)postKeyboardEventForKeyCode:(CGKeyCode)keyCode down:(BOOL)down;
- (void)postKeyboardTapForKeyCode:(CGKeyCode)keyCode flags:(CGEventFlags)flags;
- (void)postMouseButton:(CGMouseButton)button down:(BOOL)down;
- (void)postScrollX:(int32_t)scrollX scrollY:(int32_t)scrollY;
- (void)postEventToAllTaps:(CGEventRef)event;
- (void)postSystemKey:(int64_t)key down:(BOOL)down;
- (void)moveCursorByDeltaX:(double)deltaX deltaY:(double)deltaY;
- (void)openLaunchpad;
- (void)openURLString:(const std::string&)urlString;
- (void)openApplicationTarget:(const std::string&)appTarget;
- (void)runShellCommandString:(const std::string&)commandString;
- (void)openFilePath:(const std::string&)filePath withApplication:(const std::string&)applicationTarget;
- (void)runMacro:(BindingMacroKind)macroKind;
- (void)performComboMacro:(BindingMacroKind)macroKind down:(BOOL)down keyboardEnabled:(BOOL)keyboardEnabled mouseEnabled:(BOOL)mouseEnabled;
- (NSString*)documentsCapturePathWithPrefix:(NSString*)prefix extension:(NSString*)extension;
- (void)takeScreenshot;
- (void)startScreenRecording;
- (void)stopScreenRecording;
- (BOOL)isScreenRecordingActive;
- (void)showCapturePreviewForPath:(NSString*)path;
- (void)hideCapturePreview:(NSTimer*)timer;
- (BOOL)processRightStickMouseFromData:(NSDictionary*)joyconData state:(DeviceState&)state;
- (void)processMouseSensorFromData:(NSDictionary*)joyconData state:(DeviceState&)state;
- (void)performPressAction:(const BindingAction&)action down:(BOOL)down keyboardEnabled:(BOOL)keyboardEnabled mouseEnabled:(BOOL)mouseEnabled;
- (void)performTapAction:(const BindingAction&)action keyboardEnabled:(BOOL)keyboardEnabled mouseEnabled:(BOOL)mouseEnabled;
- (void)processButtonBindings:(uint32_t)buttons state:(DeviceState&)state keyboardEnabled:(BOOL)keyboardEnabled mouseEnabled:(BOOL)mouseEnabled;
- (void)processLeftStickFromData:(NSDictionary*)joyconData state:(DeviceState&)state;
@end

CGEventRef eventTapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon);

@implementation Joycon2VirtualHID

@synthesize initialized = _initialized;
@synthesize emulationMode = _emulationMode;

- (instancetype)initWithMode:(EmulationMode)mode {
    return [self initWithMode:mode modeOverridden:YES configPath:nil];
}

- (instancetype)initWithMode:(EmulationMode)mode modeOverridden:(BOOL)modeOverridden configPath:(NSString*)configPath {
    self = [super init];
    if (!self) {
        return nil;
    }

    _modeOverridden = modeOverridden;
    _configPath = [configPath copy];
    self.emulationMode = mode;
    self.initialized = NO;
    _eventSource = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    if (!_eventSource) {
        _eventSource = CGEventSourceCreate(kCGEventSourceStateCombinedSessionState);
    }

#ifndef HID_ENABLE
    joyconClient = [Joycon2BLEReceiver sharedInstance];
    if (!joyconClient) {
        NSLog(@"Failed to get Joy-Con BLE receiver instance");
        return nil;
    }

    [self loadConfig];
    if (!_modeOverridden) {
        self.emulationMode = _config.defaultMode;
    }

    __block Joycon2VirtualHID *blockSelf = self;
    joyconClient.onDataReceived = ^(NSDictionary* data) {
        [blockSelf sendHIDReportFromJoyconData:data];
    };
    joyconClient.onConnected = ^{
        blockSelf.initialized = NO;
    };
    joyconClient.onError = ^(NSString* error) {
        NSLog(@"Joy-Con error: %@", error);
    };
#endif

    NSLog(@"HID event injection ready in mode: %@", ModeName(self.emulationMode));
    return self;
}

- (void)dealloc {
    if ([self isScreenRecordingActive]) {
        [self stopScreenRecording];
    }
    if (_capturePreviewTimer) {
        [_capturePreviewTimer invalidate];
        [_capturePreviewTimer release];
        _capturePreviewTimer = nil;
    }
    if (_capturePreviewWindow) {
        [_capturePreviewWindow orderOut:nil];
        [_capturePreviewWindow release];
        _capturePreviewWindow = nil;
    }
    [_screenRecordingPath release];
    if (_eventSource) {
        CFRelease(_eventSource);
        _eventSource = NULL;
    }
    [self stopEmulation];
    [_configPath release];
    [super dealloc];
}

- (void)loadConfig {
    _config = RuntimeConfig();
    [self installDefaultBindings];

    NSString* resolvedPath = _configPath;
    if (!resolvedPath || resolvedPath.length == 0) {
        NSString* appSupportDir = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
        NSString* appSupportConfig = appSupportDir ? [[appSupportDir stringByAppendingPathComponent:@"JoyCon2forMac"] stringByAppendingPathComponent:@"joycon2_config.json"] : nil;
        NSString* currentDirConfig = [[[NSFileManager defaultManager] currentDirectoryPath] stringByAppendingPathComponent:@"joycon2_config.json"];
        NSString* bundledConfig = [[NSBundle mainBundle] pathForResource:@"joycon2_config" ofType:@"json"];

        if (appSupportConfig && [[NSFileManager defaultManager] fileExistsAtPath:appSupportConfig]) {
            resolvedPath = appSupportConfig;
        } else if ([[NSFileManager defaultManager] fileExistsAtPath:currentDirConfig]) {
            resolvedPath = currentDirConfig;
        } else {
            resolvedPath = bundledConfig ?: currentDirConfig;
        }
    }

    if (![[NSFileManager defaultManager] fileExistsAtPath:resolvedPath]) {
        _config.loadedFrom = [resolvedPath UTF8String];
        NSLog(@"Config file not found at %@, using defaults", resolvedPath);
        return;
    }

    NSData* data = [NSData dataWithContentsOfFile:resolvedPath];
    if (!data) {
        NSLog(@"Failed to read config at %@, using defaults", resolvedPath);
        return;
    }

    NSError* error = nil;
    id rootObject = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (![rootObject isKindOfClass:[NSDictionary class]]) {
        NSLog(@"Invalid config JSON at %@: %@", resolvedPath, error.localizedDescription);
        return;
    }

    NSDictionary* root = (NSDictionary*)rootObject;
    _config.loadedFrom = [resolvedPath UTF8String];

    NSString* modeValue = root[@"mode"];
    if ([modeValue isKindOfClass:[NSString class]]) {
        _config.defaultMode = ModeFromString(modeValue);
    }

    NSNumber* enableLeft = root[@"enableLeftJoyCon"];
    if ([enableLeft isKindOfClass:[NSNumber class]]) {
        _config.enableLeftJoyCon = [enableLeft boolValue];
    }

    NSDictionary* mouse = root[@"mouse"];
    if ([mouse isKindOfClass:[NSDictionary class]]) {
        NSNumber* sensitivity = mouse[@"sensitivity"];
        NSNumber* rightStickSensitivity = mouse[@"rightStickSensitivity"];
        NSNumber* deadzone = mouse[@"deadzone"];
        NSNumber* smoothing = mouse[@"smoothing"];
        NSNumber* maxStep = mouse[@"maxStep"];
        NSNumber* jumpThreshold = mouse[@"jumpThreshold"];
        NSNumber* calibrationSeconds = mouse[@"calibrationSeconds"];
        NSNumber* invertX = mouse[@"invertX"];
        NSNumber* invertY = mouse[@"invertY"];
        NSNumber* scrollStep = mouse[@"scrollStep"];
        if ([sensitivity isKindOfClass:[NSNumber class]]) _config.mouse.sensitivity = [sensitivity doubleValue];
        if ([rightStickSensitivity isKindOfClass:[NSNumber class]]) {
            _config.mouse.rightStickSensitivity = [rightStickSensitivity doubleValue];
        } else if ([sensitivity isKindOfClass:[NSNumber class]]) {
            _config.mouse.rightStickSensitivity = [sensitivity doubleValue];
        }
        if ([deadzone isKindOfClass:[NSNumber class]]) _config.mouse.deadzone = [deadzone doubleValue];
        if ([smoothing isKindOfClass:[NSNumber class]]) _config.mouse.smoothing = [smoothing doubleValue];
        if ([maxStep isKindOfClass:[NSNumber class]]) _config.mouse.maxStep = [maxStep doubleValue];
        if ([jumpThreshold isKindOfClass:[NSNumber class]]) _config.mouse.jumpThreshold = [jumpThreshold doubleValue];
        if ([calibrationSeconds isKindOfClass:[NSNumber class]]) _config.mouse.calibrationSeconds = std::max(0.0, [calibrationSeconds doubleValue]);
        if ([invertX isKindOfClass:[NSNumber class]]) _config.mouse.invertX = [invertX boolValue];
        if ([invertY isKindOfClass:[NSNumber class]]) _config.mouse.invertY = [invertY boolValue];
        if ([scrollStep isKindOfClass:[NSNumber class]]) _config.mouse.scrollStep = std::max(1, [scrollStep intValue]);
    }

    NSDictionary* keyboard = root[@"keyboard"];
    if ([keyboard isKindOfClass:[NSDictionary class]]) {
        NSNumber* stickDeadzone = keyboard[@"stickDeadzone"];
        NSString* leftStickMode = keyboard[@"leftStickMode"];
        if ([stickDeadzone isKindOfClass:[NSNumber class]]) _config.keyboard.stickDeadzone = [stickDeadzone doubleValue];
        if ([leftStickMode isKindOfClass:[NSString class]]) _config.keyboard.leftStickMode = ToLower([leftStickMode UTF8String]);
    }

    NSDictionary* bindings = root[@"bindings"];
    if ([bindings isKindOfClass:[NSDictionary class]]) {
        LoadBindingsFromDictionary(bindings, _config.bindings, _config, @"bindings");
    }

    NSDictionary* modeBindings = root[@"modeBindings"];
    if ([modeBindings isKindOfClass:[NSDictionary class]]) {
        LoadBindingsFromDictionary(modeBindings[@"mouse"], _config.mouseBindings, _config, @"modeBindings.mouse");
        LoadBindingsFromDictionary(modeBindings[@"keyboard"], _config.keyboardBindings, _config, @"modeBindings.keyboard");
        LoadBindingsFromDictionary(modeBindings[@"hybrid"], _config.hybridBindings, _config, @"modeBindings.hybrid");
        LoadBindingsFromDictionary(modeBindings[@"gamepad"], _config.gamepadBindings, _config, @"modeBindings.gamepad");
    }

    NSLog(@"Loaded config from %@ (mode=%@, leftJoyCon=%@)", resolvedPath, ModeName(_config.defaultMode), _config.enableLeftJoyCon ? @"enabled" : @"disabled");
}

- (void)installDefaultBindings {
    auto masks = ButtonMaskMap();
    auto bindPress = [&](std::map<uint32_t, ButtonBinding>& target, const std::string& button, NSString* actionString) {
        auto it = masks.find(button);
        if (it == masks.end()) {
            return;
        }
        BindingAction action = ParseActionString(actionString, _config);
        if (action.kind != BindingActionKindNone) {
            target[it->second].pressAction = action;
        }
    };
    auto bindTap = [&](std::map<uint32_t, ButtonBinding>& target, const std::string& button, NSString* actionString) {
        auto it = masks.find(button);
        if (it == masks.end()) {
            return;
        }
        BindingAction action = ParseActionString(actionString, _config);
        if (action.kind != BindingActionKindNone) {
            target[it->second].tapAction = action;
        }
    };

    _config.bindings.clear();
    _config.mouseBindings.clear();
    _config.keyboardBindings.clear();
    _config.hybridBindings.clear();
    _config.gamepadBindings.clear();

    bindTap(_config.mouseBindings, "A", @"key:space");
    bindPress(_config.mouseBindings, "R", @"mouse:left");
    bindTap(_config.mouseBindings, "B", @"system:shift_delete");
    bindPress(_config.mouseBindings, "ZR", @"mouse:left");
    bindPress(_config.mouseBindings, "X", @"key:f");
    bindPress(_config.mouseBindings, "Y", @"key:e");
    bindPress(_config.mouseBindings, "L", @"mouse:scroll_up");
    bindPress(_config.mouseBindings, "ZL", @"mouse:right");
    bindPress(_config.mouseBindings, "UP", @"system:pov");
    bindPress(_config.mouseBindings, "DOWN", @"key:q");
    bindTap(_config.mouseBindings, "LEFT", @"key:left_arrow");
    bindTap(_config.mouseBindings, "RIGHT", @"key:t");
    bindPress(_config.mouseBindings, "SL(L)", @"mouse:scroll_up");
    bindPress(_config.mouseBindings, "SR(L)", @"mouse:scroll_down");
    bindPress(_config.mouseBindings, "SL(R)", @"mouse:scroll_up");
    bindTap(_config.mouseBindings, "LS", @"system:double_w");
    bindPress(_config.mouseBindings, "RS", @"system:pov");
    bindPress(_config.mouseBindings, "SELECT", @"key:escape");
    bindPress(_config.mouseBindings, "START", @"key:escape");
    bindPress(_config.mouseBindings, "HOME", @"system:launchpad");
    bindPress(_config.mouseBindings, "CAMERA", @"system:screenshot");
    bindPress(_config.mouseBindings, "CHAT", @"system:discord");

    bindTap(_config.hybridBindings, "A", @"key:space");
    bindTap(_config.hybridBindings, "B", @"system:shift_delete");
    bindPress(_config.hybridBindings, "X", @"key:f");
    bindPress(_config.hybridBindings, "Y", @"key:e");
    bindPress(_config.hybridBindings, "R", @"mouse:scroll_down");
    bindPress(_config.hybridBindings, "ZR", @"mouse:left");
    bindPress(_config.hybridBindings, "L", @"mouse:scroll_up");
    bindPress(_config.hybridBindings, "ZL", @"mouse:right");
    bindPress(_config.hybridBindings, "UP", @"system:pov");
    bindPress(_config.hybridBindings, "DOWN", @"key:q");
    bindTap(_config.hybridBindings, "LEFT", @"key:left_arrow");
    bindTap(_config.hybridBindings, "RIGHT", @"key:t");
    bindPress(_config.hybridBindings, "SL(L)", @"mouse:scroll_up");
    bindPress(_config.hybridBindings, "SR(L)", @"mouse:scroll_down");
    bindPress(_config.hybridBindings, "SL(R)", @"mouse:scroll_up");
    bindTap(_config.hybridBindings, "LS", @"system:double_w");
    bindPress(_config.hybridBindings, "RS", @"system:pov");
    bindPress(_config.hybridBindings, "SELECT", @"key:escape");
    bindPress(_config.hybridBindings, "START", @"key:escape");
    bindPress(_config.hybridBindings, "HOME", @"system:launchpad");
    bindPress(_config.hybridBindings, "CAMERA", @"system:screenshot");
    bindPress(_config.hybridBindings, "CHAT", @"system:discord");

    bindTap(_config.keyboardBindings, "A", @"key:space");
    bindTap(_config.keyboardBindings, "B", @"system:shift_delete");
    bindPress(_config.keyboardBindings, "X", @"key:f");
    bindPress(_config.keyboardBindings, "Y", @"key:e");
    bindPress(_config.keyboardBindings, "R", @"mouse:scroll_down");
    // Keyboard mode: keep ZR as a key by default (use Hybrid for mouse clicks).
    bindPress(_config.keyboardBindings, "ZR", @"key:left_control");
    bindPress(_config.keyboardBindings, "L", @"mouse:scroll_up");
    bindPress(_config.keyboardBindings, "ZL", @"mouse:right");
    bindPress(_config.keyboardBindings, "UP", @"system:pov");
    bindPress(_config.keyboardBindings, "DOWN", @"key:q");
    bindTap(_config.keyboardBindings, "LEFT", @"key:left_arrow");
    bindTap(_config.keyboardBindings, "RIGHT", @"key:t");
    bindPress(_config.keyboardBindings, "SL(L)", @"mouse:scroll_up");
    bindPress(_config.keyboardBindings, "SR(L)", @"mouse:scroll_down");
    bindPress(_config.keyboardBindings, "SL(R)", @"mouse:scroll_up");
    bindTap(_config.keyboardBindings, "LS", @"system:double_w");
    bindPress(_config.keyboardBindings, "RS", @"system:pov");
    bindPress(_config.keyboardBindings, "SELECT", @"key:escape");
    bindPress(_config.keyboardBindings, "START", @"key:escape");
    bindPress(_config.keyboardBindings, "HOME", @"system:launchpad");
    bindPress(_config.keyboardBindings, "CAMERA", @"system:screenshot");
    bindPress(_config.keyboardBindings, "CHAT", @"system:discord");

    // Default gamepad mapping: Joy-Con button labels map to the same named gamepad buttons.
    bindPress(_config.gamepadBindings, "A", @"gamepad:a");
    bindPress(_config.gamepadBindings, "B", @"gamepad:b");
    bindPress(_config.gamepadBindings, "X", @"gamepad:x");
    bindPress(_config.gamepadBindings, "Y", @"gamepad:y");
    bindPress(_config.gamepadBindings, "L", @"gamepad:l1");
    bindPress(_config.gamepadBindings, "R", @"gamepad:r1");
    bindPress(_config.gamepadBindings, "ZL", @"gamepad:l2");
    bindPress(_config.gamepadBindings, "ZR", @"gamepad:r2");
    bindPress(_config.gamepadBindings, "UP", @"gamepad:dpad_up");
    bindPress(_config.gamepadBindings, "DOWN", @"gamepad:dpad_down");
    bindPress(_config.gamepadBindings, "LEFT", @"gamepad:dpad_left");
    bindPress(_config.gamepadBindings, "RIGHT", @"gamepad:dpad_right");
    bindPress(_config.gamepadBindings, "LS", @"gamepad:l3");
    bindPress(_config.gamepadBindings, "RS", @"gamepad:r3");
    bindPress(_config.gamepadBindings, "SELECT", @"gamepad:minus");
    bindPress(_config.gamepadBindings, "START", @"gamepad:plus");
    bindPress(_config.gamepadBindings, "HOME", @"gamepad:home");
    bindPress(_config.gamepadBindings, "CAMERA", @"gamepad:capture");
}

- (void)startEmulation {
#ifndef HID_ENABLE
    [joyconClient startScan];
#endif
    [self ensureAccessibilityPermission];
    [self setupKeyboardEventTap];
    [self setupGamepadDeviceIfNeeded];
    NSLog(@"Started Joy-Con emulation in %@ mode", ModeName(self.emulationMode));
}

- (void)stopEmulation {
    [self releaseAllPressedInputs];
#ifndef HID_ENABLE
    [joyconClient disconnect];
#endif
    [self destroyGamepadDevice];
    if (_eventTap) {
        CFMachPortInvalidate(_eventTap);
        CFRelease(_eventTap);
        _eventTap = NULL;
    }
}

CGEventRef eventTapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon) {
    Joycon2VirtualHID *self = (__bridge Joycon2VirtualHID *)refcon;
    if (type != kCGEventKeyDown) {
        return event;
    }

    CGKeyCode keyCode = (CGKeyCode)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
    CGEventFlags flags = CGEventGetFlags(event);
    CGEventFlags requiredFlags = kCGEventFlagMaskCommand | kCGEventFlagMaskControl | kCGEventFlagMaskAlternate;
    if ((flags & requiredFlags) != requiredFlags) {
        return event;
    }

    if (keyCode == 46) { // M
        [self switchToMode:MODE_MOUSE];
        return NULL;
    }
    if (keyCode == 40) { // K
        [self switchToMode:MODE_KEYBOARD];
        return NULL;
    }
    if (keyCode == 4) { // H
        [self switchToMode:MODE_HYBRID];
        return NULL;
    }
    if (keyCode == 5) { // G
        [self switchToMode:MODE_GAMEPAD];
        return NULL;
    }

    return event;
}

- (void)ensureAccessibilityPermission {
    NSDictionary* options = @{(__bridge NSString*)kAXTrustedCheckOptionPrompt: @YES};
    if (!AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options)) {
        NSLog(@"Accessibility access is not granted yet. Input injection may not work until JoyCon2forMac is allowed in System Settings > Privacy & Security > Accessibility.");
        PromptForAccessibilityIfNeeded();
    }
}

- (void)setupKeyboardEventTap {
    if (_eventTap) {
        return;
    }

    CGEventMask eventMask = CGEventMaskBit(kCGEventKeyDown);
    _eventTap = CGEventTapCreate(kCGSessionEventTap,
                                 kCGHeadInsertEventTap,
                                 kCGEventTapOptionDefault,
                                 eventMask,
                                 eventTapCallback,
                                 (__bridge void *)self);
    if (!_eventTap) {
        NSLog(@"Failed to create event tap. Grant Accessibility access in System Settings.");
        PromptForAccessibilityIfNeeded();
        return;
    }

    CFRunLoopSourceRef runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, _eventTap, 0);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, kCFRunLoopCommonModes);
    CFRelease(runLoopSource);
    CGEventTapEnable(_eventTap, true);
}

- (void)setupGamepadDeviceIfNeeded {
    if (_gamepadDevice) {
        return;
    }
    if (self.emulationMode != MODE_GAMEPAD) {
        return;
    }

    static const uint8_t kGamepadReportDescriptor[] = {
        0x05, 0x01,        // Usage Page (Generic Desktop)
        0x09, 0x05,        // Usage (Game Pad)
        0xA1, 0x01,        // Collection (Application)
        0x05, 0x09,        //   Usage Page (Button)
        0x19, 0x01,        //   Usage Minimum (Button 1)
        0x29, 0x10,        //   Usage Maximum (Button 16)
        0x15, 0x00,        //   Logical Minimum (0)
        0x25, 0x01,        //   Logical Maximum (1)
        0x75, 0x01,        //   Report Size (1)
        0x95, 0x10,        //   Report Count (16)
        0x81, 0x02,        //   Input (Data,Var,Abs)
        0x05, 0x01,        //   Usage Page (Generic Desktop)
        0x09, 0x39,        //   Usage (Hat switch)
        0x15, 0x00,        //   Logical Minimum (0)
        0x25, 0x07,        //   Logical Maximum (7)
        0x35, 0x00,        //   Physical Minimum (0)
        0x46, 0x3B, 0x01,  //   Physical Maximum (315)
        0x65, 0x14,        //   Unit (Eng Rot: Degree)
        0x75, 0x04,        //   Report Size (4)
        0x95, 0x01,        //   Report Count (1)
        0x81, 0x42,        //   Input (Data,Var,Abs,Null)
        0x75, 0x04,        //   Report Size (4)
        0x95, 0x01,        //   Report Count (1)
        0x81, 0x03,        //   Input (Cnst,Var,Abs)
        0x09, 0x30,        //   Usage (X)
        0x09, 0x31,        //   Usage (Y)
        0x09, 0x33,        //   Usage (Rx)
        0x09, 0x34,        //   Usage (Ry)
        0x15, 0x81,        //   Logical Minimum (-127)
        0x25, 0x7F,        //   Logical Maximum (127)
        0x75, 0x08,        //   Report Size (8)
        0x95, 0x04,        //   Report Count (4)
        0x81, 0x02,        //   Input (Data,Var,Abs)
        0xC0               // End Collection
    };

    NSData* descriptor = [NSData dataWithBytes:kGamepadReportDescriptor length:sizeof(kGamepadReportDescriptor)];
    NSDictionary* properties = @{
        @kIOHIDReportDescriptorKey: descriptor,
        @kIOHIDVendorIDKey: @(0xF0D0),
        @kIOHIDProductIDKey: @(0x0001),
        @kIOHIDVersionNumberKey: @(0x0001),
        @kIOHIDManufacturerKey: @"JoyCon2forMac",
        @kIOHIDProductKey: @"JoyCon2forMac Gamepad",
        @kIOHIDPrimaryUsagePageKey: @(0x01),
        @kIOHIDPrimaryUsageKey: @(0x05),
    };

    _gamepadDevice = IOHIDUserDeviceCreate(kCFAllocatorDefault, (CFDictionaryRef)properties);
    if (!_gamepadDevice) {
        NSLog(@"Failed to create virtual gamepad device (likely blocked by macOS policy/entitlements). Gamepad buttons will not work, but mouse/keyboard bindings can still be used.");
        return;
    }

    _gamepadButtons = 0;
    _gamepadDpadUp = false;
    _gamepadDpadDown = false;
    _gamepadDpadLeft = false;
    _gamepadDpadRight = false;
    _gamepadLX = 0;
    _gamepadLY = 0;
    _gamepadRX = 0;
    _gamepadRY = 0;
    [self sendGamepadReport];
}

- (void)destroyGamepadDevice {
    if (_gamepadDevice) {
        CFRelease(_gamepadDevice);
        _gamepadDevice = NULL;
    }
}

- (void)sendGamepadReport {
    if (!_gamepadDevice) {
        return;
    }

    uint8_t hat = 8;
    if (_gamepadDpadUp && _gamepadDpadRight) hat = 1;
    else if (_gamepadDpadRight && _gamepadDpadDown) hat = 3;
    else if (_gamepadDpadDown && _gamepadDpadLeft) hat = 5;
    else if (_gamepadDpadLeft && _gamepadDpadUp) hat = 7;
    else if (_gamepadDpadUp) hat = 0;
    else if (_gamepadDpadRight) hat = 2;
    else if (_gamepadDpadDown) hat = 4;
    else if (_gamepadDpadLeft) hat = 6;

    uint8_t report[7];
    report[0] = (uint8_t)(_gamepadButtons & 0xFF);
    report[1] = (uint8_t)((_gamepadButtons >> 8) & 0xFF);
    report[2] = (uint8_t)(hat & 0x0F);
    report[3] = (uint8_t)_gamepadLX;
    report[4] = (uint8_t)_gamepadLY;
    report[5] = (uint8_t)_gamepadRX;
    report[6] = (uint8_t)_gamepadRY;

    IOReturn result = IOHIDUserDeviceHandleReport(_gamepadDevice, report, sizeof(report));
    if (result != kIOReturnSuccess) {
        // Avoid spamming logs; failures here typically mean the OS rejected the virtual device.
    }
}

- (void)setGamepadButtonMask:(uint16_t)mask down:(BOOL)down {
    if (down) {
        _gamepadButtons |= mask;
    } else {
        _gamepadButtons &= (uint16_t)~mask;
    }
    [self sendGamepadReport];
}

- (void)setGamepadDpadDirection:(uint8_t)direction down:(BOOL)down {
    switch (direction) {
        case 0: _gamepadDpadUp = down; break;
        case 1: _gamepadDpadDown = down; break;
        case 2: _gamepadDpadLeft = down; break;
        case 3: _gamepadDpadRight = down; break;
        default: break;
    }
    [self sendGamepadReport];
}

- (void)updateGamepadAxesFromJoyconData:(NSDictionary*)joyconData deviceType:(const std::string&)deviceType {
    if (!_gamepadDevice) {
        return;
    }

    auto normalizeAxis = [](NSNumber* value, bool invert) -> int8_t {
        if (![value isKindOfClass:[NSNumber class]]) {
            return 0;
        }
        double normalized = ([value doubleValue] - 2047.0) / 2047.0;
        normalized = ClampDouble(normalized, -1.0, 1.0);
        if (invert) {
            normalized = -normalized;
        }
        int scaled = (int)llround(normalized * 127.0);
        if (scaled < -127) scaled = -127;
        if (scaled > 127) scaled = 127;
        return (int8_t)scaled;
    };

    if (deviceType == "L" || deviceType == "Unknown") {
        NSNumber* lx = joyconData[@"LeftStickX"];
        NSNumber* ly = joyconData[@"LeftStickY"];
        _gamepadLX = normalizeAxis(lx, false);
        _gamepadLY = normalizeAxis(ly, true);
    }
    if (deviceType == "R" || deviceType == "Unknown") {
        NSNumber* rx = joyconData[@"RightStickX"];
        NSNumber* ry = joyconData[@"RightStickY"];
        _gamepadRX = normalizeAxis(rx, false);
        _gamepadRY = normalizeAxis(ry, true);
    }

    [self sendGamepadReport];
}

- (void)moveCursorByDeltaX:(double)deltaX deltaY:(double)deltaY {
    BOOL cursorVisible = CGCursorIsVisible();
    CGPoint currentPos = _cursorPosition;
    if (cursorVisible || !_hasCursorPosition) {
        CGEventRef tempEvent = CGEventCreate(NULL);
        currentPos = CGEventGetLocation(tempEvent);
        CFRelease(tempEvent);
        _cursorPosition = currentPos;
        _hasCursorPosition = YES;
    }

    CGPoint nextPos = currentPos;
    nextPos.x += deltaX;
    nextPos.y += deltaY;

    CGRect screenBounds = CGDisplayBounds(CGMainDisplayID());
    nextPos.x = fmax(screenBounds.origin.x, fmin(nextPos.x, screenBounds.origin.x + screenBounds.size.width));
    nextPos.y = fmax(screenBounds.origin.y, fmin(nextPos.y, screenBounds.origin.y + screenBounds.size.height));

    CGMouseButton eventButton = kCGMouseButtonLeft;
    CGEventType eventType = kCGEventMouseMoved;
    if (_leftMouseHeld) {
        eventType = kCGEventLeftMouseDragged;
        eventButton = kCGMouseButtonLeft;
    } else if (_rightMouseHeld) {
        eventType = kCGEventRightMouseDragged;
        eventButton = kCGMouseButtonRight;
    } else if (_middleMouseHeld) {
        eventType = kCGEventOtherMouseDragged;
        eventButton = kCGMouseButtonCenter;
    }

    if (!cursorVisible) {
        CGEventRef relativeEvent = CGEventCreateMouseEvent(_eventSource, kCGEventMouseMoved, currentPos, kCGMouseButtonLeft);
        if (relativeEvent) {
            CGEventSetIntegerValueField(relativeEvent, kCGMouseEventDeltaX, (int64_t)llround(deltaX));
            CGEventSetIntegerValueField(relativeEvent, kCGMouseEventDeltaY, (int64_t)llround(deltaY));
            [self postEventToAllTaps:relativeEvent];
            CFRelease(relativeEvent);
        }
    }

    CGEventRef absoluteEvent = CGEventCreateMouseEvent(_eventSource, eventType, nextPos, eventButton);
    if (absoluteEvent) {
        CGEventSetIntegerValueField(absoluteEvent, kCGMouseEventDeltaX, (int64_t)llround(deltaX));
        CGEventSetIntegerValueField(absoluteEvent, kCGMouseEventDeltaY, (int64_t)llround(deltaY));
        [self postEventToAllTaps:absoluteEvent];
        CFRelease(absoluteEvent);
    }

    _cursorPosition = nextPos;
}

- (void)openLaunchpad {
    [self postSystemKey:NX_KEYTYPE_LAUNCH_PANEL down:YES];
    usleep(10000);
    [self postSystemKey:NX_KEYTYPE_LAUNCH_PANEL down:NO];
}

- (void)postEventToAllTaps:(CGEventRef)event {
    if (!event) {
        return;
    }
    // kCGHIDEventTap is the most reliable injection target for mouse movement/clicks across apps.
    CGEventPost(kCGHIDEventTap, event);
}

- (void)postSystemKey:(int64_t)key down:(BOOL)down {
    NSInteger state = down ? NX_KEYDOWN : NX_KEYUP;
    NSInteger data1 = (key << 16) | (state << 8);
    NSEvent* event = [NSEvent otherEventWithType:NSEventTypeSystemDefined
                                        location:NSZeroPoint
                                   modifierFlags:0
                                       timestamp:0
                                    windowNumber:0
                                         context:nil
                                         subtype:NX_SUBTYPE_AUX_CONTROL_BUTTONS
                                           data1:(int32_t)data1
                                           data2:-1];
    if (event) {
        [self postEventToAllTaps:[event CGEvent]];
    }
}

- (void)openURLString:(const std::string&)urlString {
    if (urlString.empty()) {
        return;
    }
    NSString* url = [NSString stringWithUTF8String:urlString.c_str()];
    NSURL* targetURL = [NSURL URLWithString:url];
    if (targetURL) {
        [[NSWorkspace sharedWorkspace] openURL:targetURL];
    }
}

- (void)openApplicationTarget:(const std::string&)appTarget {
    if (appTarget.empty()) {
        return;
    }
    NSString* target = [NSString stringWithUTF8String:appTarget.c_str()];
    if (!target.length) {
        return;
    }

    NSString* expandedTarget = [target stringByExpandingTildeInPath];
    if ([expandedTarget hasPrefix:@"/"] || [expandedTarget hasSuffix:@".app"]) {
        NSURL* appURL = [NSURL fileURLWithPath:expandedTarget];
        if (appURL) {
            [[NSWorkspace sharedWorkspace] openURL:appURL];
            return;
        }
    }

    NSTask* task = [[NSTask alloc] init];
    task.launchPath = @"/usr/bin/open";
    task.arguments = @[@"-a", target];
    [task launch];
    [task release];
}

- (void)runShellCommandString:(const std::string&)commandString {
    if (commandString.empty()) {
        return;
    }
    NSString* command = [NSString stringWithUTF8String:commandString.c_str()];
    if (!command.length) {
        return;
    }

    NSTask* task = [[NSTask alloc] init];
    task.launchPath = @"/bin/zsh";
    task.arguments = @[@"-lc", command];
    [task launch];
    [task release];
}

- (void)openFilePath:(const std::string&)filePath withApplication:(const std::string&)applicationTarget {
    if (filePath.empty()) {
        return;
    }
    NSString* targetPath = [[NSString stringWithUTF8String:filePath.c_str()] stringByExpandingTildeInPath];
    if (!targetPath.length) {
        return;
    }

    if (applicationTarget.empty()) {
        NSURL* fileURL = [NSURL fileURLWithPath:targetPath];
        if (fileURL) {
            [[NSWorkspace sharedWorkspace] openURL:fileURL];
        }
        return;
    }

    NSString* appTarget = [[NSString stringWithUTF8String:applicationTarget.c_str()] stringByExpandingTildeInPath];
    NSTask* task = [[NSTask alloc] init];
    task.launchPath = @"/usr/bin/open";
    task.arguments = @[@"-a", appTarget, targetPath];
    [task launch];
    [task release];
}

- (void)runMacro:(BindingMacroKind)macroKind {
    switch (macroKind) {
        case BindingMacroKindPOV:
            [self postKeyboardTapForKeyCode:96 flags:kCGEventFlagMaskSecondaryFn];
            break;
        case BindingMacroKindDoubleW: {
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (_lastDoubleWAt > 0.0 && (now - _lastDoubleWAt) < 1.5) {
                break;
            }
            _lastDoubleWAt = now;
            [self postKeyboardEventForKeyCode:13 down:YES];
            [self postKeyboardEventForKeyCode:13 down:NO];
            usleep(250000);
            [self postKeyboardEventForKeyCode:13 down:YES];
            [self postKeyboardEventForKeyCode:13 down:NO];
            break;
        }
        case BindingMacroKindSpaceClick:
        case BindingMacroKindShiftDelete:
        case BindingMacroKindNone:
        default:
            break;
    }
}

- (void)performComboMacro:(BindingMacroKind)macroKind down:(BOOL)down keyboardEnabled:(BOOL)keyboardEnabled mouseEnabled:(BOOL)mouseEnabled {
    switch (macroKind) {
        case BindingMacroKindSpaceClick:
            if (keyboardEnabled && !CGCursorIsVisible()) {
                if (down) {
                    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
                    if (_lastSpaceTapAt > 0.0 && (now - _lastSpaceTapAt) < 0.35) {
                        break;
                    }
                    _lastSpaceTapAt = now;
                }
                [self postKeyboardEventForKeyCode:49 down:down];
            }
            if (mouseEnabled && CGCursorIsVisible()) {
                [self postMouseButton:kCGMouseButtonLeft down:down];
            }
            break;
        case BindingMacroKindShiftDelete:
            if (keyboardEnabled) {
                [self postKeyboardEventForKeyCode:56 down:down];
                [self postKeyboardEventForKeyCode:51 down:down];
            }
            break;
        case BindingMacroKindPOV:
        case BindingMacroKindDoubleW:
        case BindingMacroKindNone:
        default:
            break;
    }
}

- (NSString*)documentsCapturePathWithPrefix:(NSString*)prefix extension:(NSString*)extension {
    NSString* documentsDirectory = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSDateFormatter* formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"yyyy-MM-dd_HH-mm-ss";
    NSString* timestamp = [formatter stringFromDate:[NSDate date]];
    [formatter release];
    NSString* fileName = [NSString stringWithFormat:@"%@_%@.%@", prefix, timestamp, extension];
    return [documentsDirectory stringByAppendingPathComponent:fileName];
}

- (void)takeScreenshot {
    NSString* outputPath = [self documentsCapturePathWithPrefix:@"joycon2_screenshot" extension:@"png"];
    NSTask* task = [[NSTask alloc] init];
    task.launchPath = @"/usr/sbin/screencapture";
    task.arguments = @[@"-x", outputPath];
    [task launch];
    [task waitUntilExit];
    NSLog(@"Saved JoyCon2 screenshot to %@", outputPath);
    [self showCapturePreviewForPath:outputPath];
    [task release];
}

- (BOOL)isScreenRecordingActive {
    return _screenRecordingTask != nil && _screenRecordingTask.isRunning;
}

- (void)startScreenRecording {
    if ([self isScreenRecordingActive]) {
        return;
    }

    [_screenRecordingPath release];
    _screenRecordingPath = [[self documentsCapturePathWithPrefix:@"joycon2_recording" extension:@"mov"] copy];

    _screenRecordingTask = [[NSTask alloc] init];
    _screenRecordingTask.launchPath = @"/usr/sbin/screencapture";
    _screenRecordingTask.arguments = @[@"-v", @"-D1", _screenRecordingPath];
    [_screenRecordingTask launch];
    NSLog(@"Started JoyCon2 screen recording: %@", _screenRecordingPath);
}

- (void)stopScreenRecording {
    if (![self isScreenRecordingActive]) {
        return;
    }

    [_screenRecordingTask interrupt];
    usleep(250000);
    if (_screenRecordingTask.isRunning) {
        [_screenRecordingTask terminate];
    }
    [_screenRecordingTask waitUntilExit];
    [_screenRecordingTask release];
    _screenRecordingTask = nil;
    if (_screenRecordingPath) {
        NSLog(@"Saved JoyCon2 screen recording to %@", _screenRecordingPath);
        [self showCapturePreviewForPath:_screenRecordingPath];
    }
}

- (void)showCapturePreviewForPath:(NSString*)path {
    if (path.length == 0) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (_capturePreviewTimer) {
            [_capturePreviewTimer invalidate];
            [_capturePreviewTimer release];
            _capturePreviewTimer = nil;
        }
        if (_capturePreviewWindow) {
            [_capturePreviewWindow orderOut:nil];
            [_capturePreviewWindow release];
            _capturePreviewWindow = nil;
        }

        NSScreen* screen = [NSScreen mainScreen];
        if (!screen) {
            return;
        }

        NSRect visibleFrame = screen.visibleFrame;
        NSRect frame = NSMakeRect(NSMaxX(visibleFrame) - 236.0, NSMinY(visibleFrame) + 24.0, 216.0, 140.0);
        _capturePreviewWindow = [[NSWindow alloc] initWithContentRect:frame
                                                            styleMask:NSWindowStyleMaskBorderless
                                                              backing:NSBackingStoreBuffered
                                                                defer:NO];
        [_capturePreviewWindow setOpaque:NO];
        [_capturePreviewWindow setBackgroundColor:[NSColor colorWithWhite:0.08 alpha:0.9]];
        [_capturePreviewWindow setHasShadow:YES];
        [_capturePreviewWindow setIgnoresMouseEvents:YES];
        [_capturePreviewWindow setLevel:NSStatusWindowLevel];

        NSView* contentView = [_capturePreviewWindow contentView];
        [contentView setWantsLayer:YES];
        contentView.layer.cornerRadius = 16.0;
        contentView.layer.masksToBounds = YES;

        NSImage* previewImage = [[[NSImage alloc] initWithContentsOfFile:path] autorelease];
        if (!previewImage) {
            previewImage = [[NSWorkspace sharedWorkspace] iconForFile:path];
        }

        NSImageView* imageView = [[[NSImageView alloc] initWithFrame:NSMakeRect(14, 34, 188, 92)] autorelease];
        [imageView setImageScaling:NSImageScaleProportionallyUpOrDown];
        [imageView setImage:previewImage];
        [contentView addSubview:imageView];

        NSTextField* label = [[[NSTextField alloc] initWithFrame:NSMakeRect(14, 10, 188, 18)] autorelease];
        [label setEditable:NO];
        [label setBezeled:NO];
        [label setDrawsBackground:NO];
        [label setTextColor:[NSColor whiteColor]];
        [label setFont:[NSFont systemFontOfSize:12 weight:NSFontWeightMedium]];
        [label setLineBreakMode:NSLineBreakByTruncatingMiddle];
        [label setStringValue:[path lastPathComponent]];
        [contentView addSubview:label];

        [_capturePreviewWindow orderFrontRegardless];

        _capturePreviewTimer = [[NSTimer scheduledTimerWithTimeInterval:4.0
                                                                 target:self
                                                               selector:@selector(hideCapturePreview:)
                                                               userInfo:nil
                                                                repeats:NO] retain];
    });
}

- (void)hideCapturePreview:(NSTimer*)timer {
    if (_capturePreviewTimer) {
        [_capturePreviewTimer invalidate];
        [_capturePreviewTimer release];
        _capturePreviewTimer = nil;
    }
    if (_capturePreviewWindow) {
        [_capturePreviewWindow orderOut:nil];
        [_capturePreviewWindow release];
        _capturePreviewWindow = nil;
    }
}

- (const ButtonBinding*)bindingForMask:(uint32_t)mask mode:(EmulationMode)mode {
    const std::map<uint32_t, ButtonBinding>* selectedBindings = nullptr;
    switch (mode) {
        case MODE_MOUSE:
            selectedBindings = &_config.mouseBindings;
            break;
        case MODE_KEYBOARD:
            selectedBindings = &_config.keyboardBindings;
            break;
        case MODE_GAMEPAD:
            selectedBindings = &_config.gamepadBindings;
            break;
        case MODE_HYBRID:
        default:
            selectedBindings = &_config.hybridBindings;
            break;
    }

    if (selectedBindings) {
        auto it = selectedBindings->find(mask);
        if (it != selectedBindings->end()) {
            return &it->second;
        }
    }

    auto fallback = _config.bindings.find(mask);
    if (fallback != _config.bindings.end()) {
        return &fallback->second;
    }

    return nullptr;
}

- (void)switchToMode:(EmulationMode)mode {
    if (self.emulationMode == mode) {
        return;
    }
    [self releaseAllPressedInputs];
    self.emulationMode = mode;
    if (mode == MODE_GAMEPAD) {
        [self setupGamepadDeviceIfNeeded];
    } else {
        [self destroyGamepadDevice];
    }
    NSLog(@"Switched to %@ mode", ModeName(mode));
}

- (void)releaseAllPressedInputs {
    BOOL keyboardEnabled = YES;
    BOOL mouseEnabled = YES;
    std::set<uint32_t> relevantMasks;
    for (const auto& entry : _config.bindings) relevantMasks.insert(entry.first);
    for (const auto& entry : _config.mouseBindings) relevantMasks.insert(entry.first);
    for (const auto& entry : _config.keyboardBindings) relevantMasks.insert(entry.first);
    for (const auto& entry : _config.hybridBindings) relevantMasks.insert(entry.first);
    for (const auto& entry : _config.gamepadBindings) relevantMasks.insert(entry.first);

    for (auto& entry : _deviceStates) {
        DeviceState& state = entry.second;
        for (uint32_t mask : relevantMasks) {
            const ButtonBinding* binding = [self bindingForMask:mask mode:self.emulationMode];
            bool isPressed = (state.lastButtons & mask) != 0;
            if (!isPressed || !binding) {
                continue;
            }

            const BindingAction& action = binding->pressAction;
            if (action.kind == BindingActionKindKey && keyboardEnabled) {
                [self postKeyboardEventForKeyCode:action.keyCode down:NO];
            } else if (action.kind == BindingActionKindMouseButton && mouseEnabled) {
                [self postMouseButton:action.mouseButton down:NO];
            }
        }

        if (state.stickUp) [self postKeyboardEventForKeyCode:(_config.keyboard.leftStickMode == "arrows" ? 126 : 13) down:NO];
        if (state.stickDown) [self postKeyboardEventForKeyCode:(_config.keyboard.leftStickMode == "arrows" ? 125 : 1) down:NO];
        if (state.stickLeft) [self postKeyboardEventForKeyCode:(_config.keyboard.leftStickMode == "arrows" ? 123 : 0) down:NO];
        if (state.stickRight) [self postKeyboardEventForKeyCode:(_config.keyboard.leftStickMode == "arrows" ? 124 : 2) down:NO];
        if (state.hybridMousePrimaryPressed) {
            [self postMouseButton:kCGMouseButtonLeft down:NO];
        }

        state.lastButtons = 0;
        state.lastRawButtons = 0;
        state.mouseModePrimaryPressed = false;
        state.hybridMousePrimaryPressed = false;
        state.buttonPressedAt.clear();
        state.stickUp = false;
        state.stickDown = false;
        state.stickLeft = false;
        state.stickRight = false;
        state.smoothedRightStickX = 0.0;
        state.smoothedRightStickY = 0.0;
    }

    _leftMouseHeld = NO;
    _rightMouseHeld = NO;
    _middleMouseHeld = NO;
    _hasCursorPosition = NO;
    _lastDoubleWAt = 0.0;
    _lastSpaceTapAt = 0.0;

    if (_gamepadDevice) {
        _gamepadButtons = 0;
        _gamepadDpadUp = false;
        _gamepadDpadDown = false;
        _gamepadDpadLeft = false;
        _gamepadDpadRight = false;
        _gamepadLX = 0;
        _gamepadLY = 0;
        _gamepadRX = 0;
        _gamepadRY = 0;
        [self sendGamepadReport];
    }
}

- (void)sendHIDReportFromJoyconData:(NSDictionary *)joyconData {
#ifndef HID_ENABLE
    NSString* deviceTypeString = joyconData[@"DeviceType"] ?: @"Unknown";
    NSString* identifier = joyconData[@"PeripheralIdentifier"] ?: @"unknown";
    std::string deviceType = [deviceTypeString UTF8String];
    std::string identifierKey = [identifier UTF8String];

    if (deviceType == "L" && !_config.enableLeftJoyCon) {
        return;
    }

    // Mouse motion is enabled in all modes so "Keyboard Controls" still has cursor movement.
    BOOL mouseMotionEnabled = (self.emulationMode == MODE_MOUSE ||
                               self.emulationMode == MODE_HYBRID ||
                               self.emulationMode == MODE_GAMEPAD ||
                               self.emulationMode == MODE_KEYBOARD);
    BOOL leftStickEnabled = (self.emulationMode == MODE_KEYBOARD || self.emulationMode == MODE_HYBRID);
    BOOL mouseEnabled = YES;
    BOOL keyboardEnabled = YES;

    bool isNewDevice = _deviceStates.find(identifierKey) == _deviceStates.end();
    DeviceState& state = _deviceStates[identifierKey];
    if (isNewDevice && (deviceType == "R" || deviceType == "Unknown")) {
        _hasCursorPosition = NO;
    }

    if (self.emulationMode == MODE_GAMEPAD) {
        // Gamepad mode is "gamepad + mouse" so the app stays usable even if virtual HID gamepads are blocked.
        // Virtual gamepad output is best-effort; mouse/keyboard injection continues to work.
        [self setupGamepadDeviceIfNeeded];
        [self updateGamepadAxesFromJoyconData:joyconData deviceType:deviceType];
    }

    if (mouseMotionEnabled && (deviceType == "R" || deviceType == "Unknown")) {
        [self processMouseSensorFromData:joyconData state:state];
    }

    NSNumber* buttonsNumber = joyconData[@"Buttons"];
    uint32_t rawButtons = buttonsNumber ? (uint32_t)[buttonsNumber unsignedLongLongValue] : 0;
    if (rawButtons != state.lastRawButtons) {
        uint32_t delta = rawButtons ^ state.lastRawButtons;
        JoyConLogThrottled([NSString stringWithFormat:@"JoyCon2 buttons changed: type=%@ buttons=0x%08x delta=0x%08x mode=%@", deviceTypeString, rawButtons, delta, ModeName(self.emulationMode)]);
    }
    uint32_t buttons = rawButtons;
    if (self.emulationMode == MODE_MOUSE) {
        const uint32_t mousePrimaryMask = 0x00004000;
        const uint32_t mousePrimaryFallbackMask = 0x00001000;
        NSNumber* triggerRNumber = joyconData[@"TriggerR"];
        int triggerRValue = triggerRNumber ? [triggerRNumber intValue] : 0;
        bool shoulderFallbackPressed = triggerRValue > 0 && (buttons & 0x00008000) == 0;
        bool primaryPressed = (buttons & mousePrimaryMask) != 0 ||
                              (buttons & mousePrimaryFallbackMask) != 0 ||
                              shoulderFallbackPressed;

        // Some Joy-Con reports expose R as an analog trigger rather than a stable bit.
        // Instead of posting a click directly here (which bypasses bindings), synthesize
        // the R bit so the regular binding pipeline can produce click/drag behavior.
        if (primaryPressed) {
            buttons |= mousePrimaryMask;
        } else {
            buttons &= ~mousePrimaryMask;
        }
        // Ignore the SR(R) fallback bit for bindings; we only use it to infer primaryPressed.
        buttons &= ~mousePrimaryFallbackMask;
    }
    if ((self.emulationMode == MODE_HYBRID || self.emulationMode == MODE_GAMEPAD) && (deviceType == "R" || deviceType == "Unknown")) {
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        const uint32_t aMask = 0x00000800;
        const uint32_t rMask = 0x00004000;
        bool aWasPressed = (state.lastRawButtons & aMask) != 0;
        bool aIsPressed = (rawButtons & aMask) != 0;
        bool rWasPressed = (state.lastRawButtons & rMask) != 0;
        bool rIsPressed = (rawButtons & rMask) != 0;
        bool mouseContextActive = (state.lastMouseIntentAt > 0.0) && ((now - state.lastMouseIntentAt) <= 1.0);

        if (aIsPressed && !aWasPressed) {
            auto lastTapIt = state.lastTapActionAt.find(aMask);
            double elapsedSinceLastTap = (lastTapIt != state.lastTapActionAt.end()) ? (now - lastTapIt->second) : 999.0;
            if (elapsedSinceLastTap >= 0.35) {
                [self postKeyboardEventForKeyCode:49 down:YES];
                [self postKeyboardEventForKeyCode:49 down:NO];
                if (!mouseContextActive) {
                    [self postMouseButton:kCGMouseButtonLeft down:YES];
                    [self postMouseButton:kCGMouseButtonLeft down:NO];
                }
                state.lastTapActionAt[aMask] = now;
            }
        }

        if (rIsPressed && !rWasPressed) {
            if (mouseContextActive) {
                [self postMouseButton:kCGMouseButtonLeft down:YES];
                state.hybridMousePrimaryPressed = true;
            } else {
                [self postScrollX:0 scrollY:-_config.mouse.scrollStep];
            }
        } else if (!rIsPressed && rWasPressed && state.hybridMousePrimaryPressed) {
            [self postMouseButton:kCGMouseButtonLeft down:NO];
            state.hybridMousePrimaryPressed = false;
        }

        buttons &= ~aMask;
        buttons &= ~rMask;
    }
    [self processButtonBindings:buttons state:state keyboardEnabled:keyboardEnabled mouseEnabled:mouseEnabled];
    state.lastRawButtons = rawButtons;

    if (leftStickEnabled && (deviceType == "L" || deviceType == "Unknown")) {
        [self processLeftStickFromData:joyconData state:state];
    }
#endif
}

- (void)processMouseSensorFromData:(NSDictionary*)joyconData state:(DeviceState&)state {
    NSNumber* mouseXNumber = joyconData[@"MouseX"];
    NSNumber* mouseYNumber = joyconData[@"MouseY"];
    BOOL rightStickMoved = [self processRightStickMouseFromData:joyconData state:state];
    if (!mouseXNumber || !mouseYNumber) {
        return;
    }

    int16_t mouseX = (int16_t)[mouseXNumber intValue];
    int16_t mouseY = (int16_t)[mouseYNumber intValue];

    if (rightStickMoved) {
        state.lastMouseIntentAt = CFAbsoluteTimeGetCurrent();
        state.lastMouseX = mouseX;
        state.lastMouseY = mouseY;
        state.hasMouseSample = true;
        state.smoothedDeltaX *= 0.5;
        state.smoothedDeltaY *= 0.5;
        if (state.calibrationEndsAt == 0.0) {
            state.calibrationEndsAt = CFAbsoluteTimeGetCurrent() + _config.mouse.calibrationSeconds;
        }
        return;
    }

    if (!state.hasMouseSample) {
        state.lastMouseX = mouseX;
        state.lastMouseY = mouseY;
        state.calibrationEndsAt = CFAbsoluteTimeGetCurrent() + _config.mouse.calibrationSeconds;
        state.hasMouseSample = true;
        return;
    }

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    double rawDeltaX = (double)(mouseX - state.lastMouseX);
    double rawDeltaY = (double)(mouseY - state.lastMouseY);
    state.lastMouseX = mouseX;
    state.lastMouseY = mouseY;

    if (std::fabs(rawDeltaX) > _config.mouse.jumpThreshold || std::fabs(rawDeltaY) > _config.mouse.jumpThreshold) {
        state.smoothedDeltaX = 0.0;
        state.smoothedDeltaY = 0.0;
        return;
    }

    if (now < state.calibrationEndsAt) {
        state.driftBiasX = (state.driftBiasX * 0.8) + (rawDeltaX * 0.2);
        state.driftBiasY = (state.driftBiasY * 0.8) + (rawDeltaY * 0.2);
        state.smoothedDeltaX = 0.0;
        state.smoothedDeltaY = 0.0;
        return;
    }

    const double driftWindow = std::max(_config.mouse.deadzone * 3.0, 6.0);
    if (std::fabs(rawDeltaX) < driftWindow) {
        state.driftBiasX = (state.driftBiasX * 0.95) + (rawDeltaX * 0.05);
    }
    if (std::fabs(rawDeltaY) < driftWindow) {
        state.driftBiasY = (state.driftBiasY * 0.95) + (rawDeltaY * 0.05);
    }

    rawDeltaX -= state.driftBiasX;
    rawDeltaY -= state.driftBiasY;

    if (std::fabs(rawDeltaX) < _config.mouse.deadzone) rawDeltaX = 0.0;
    if (std::fabs(rawDeltaY) < _config.mouse.deadzone) rawDeltaY = 0.0;

    const double carry = ClampDouble(_config.mouse.smoothing, 0.0, 0.95);
    state.smoothedDeltaX = (state.smoothedDeltaX * carry) + (rawDeltaX * (1.0 - carry));
    state.smoothedDeltaY = (state.smoothedDeltaY * carry) + (rawDeltaY * (1.0 - carry));

    if (rawDeltaX == 0.0) {
        state.smoothedDeltaX *= carry;
    }
    if (rawDeltaY == 0.0) {
        state.smoothedDeltaY *= carry;
    }

    double deltaX = state.smoothedDeltaX * _config.mouse.sensitivity;
    double deltaY = state.smoothedDeltaY * _config.mouse.sensitivity;
    if (!CGCursorIsVisible()) {
        deltaX *= 0.12;
        deltaY *= 0.12;
    }
    if (_config.mouse.invertX) deltaX = -deltaX;
    if (_config.mouse.invertY) deltaY = -deltaY;

    if (std::fabs(deltaX) < 0.01 && std::fabs(deltaY) < 0.01) {
        return;
    }

    deltaX = ClampDouble(deltaX, -_config.mouse.maxStep, _config.mouse.maxStep);
    deltaY = ClampDouble(deltaY, -_config.mouse.maxStep, _config.mouse.maxStep);

    state.lastMouseIntentAt = now;
    [self moveCursorByDeltaX:deltaX deltaY:deltaY];
}

- (BOOL)processRightStickMouseFromData:(NSDictionary*)joyconData state:(DeviceState&)state {
    NSNumber* rightStickX = joyconData[@"RightStickX"];
    NSNumber* rightStickY = joyconData[@"RightStickY"];
    if (!rightStickX || !rightStickY) {
        return NO;
    }

    if (CGCursorIsVisible()) {
        state.smoothedRightStickX = 0.0;
        state.smoothedRightStickY = 0.0;
        return NO;
    }

    double normalizedX = ([rightStickX doubleValue] - 2047.0) / 2047.0;
    double normalizedY = (2047.0 - [rightStickY doubleValue]) / 2047.0;
    double deadzone = ClampDouble(_config.keyboard.stickDeadzone, 0.0, 0.95);

    if (std::fabs(normalizedX) < deadzone) normalizedX = 0.0;
    if (std::fabs(normalizedY) < deadzone) normalizedY = 0.0;

    const double stickCarry = 0.82;
    state.smoothedRightStickX = (state.smoothedRightStickX * stickCarry) + (normalizedX * (1.0 - stickCarry));
    state.smoothedRightStickY = (state.smoothedRightStickY * stickCarry) + (normalizedY * (1.0 - stickCarry));
    if (normalizedX == 0.0) {
        state.smoothedRightStickX *= 0.7;
    }
    if (normalizedY == 0.0) {
        state.smoothedRightStickY *= 0.7;
    }

    normalizedX = state.smoothedRightStickX;
    normalizedY = state.smoothedRightStickY;
    if (std::fabs(normalizedX) < 0.01) normalizedX = 0.0;
    if (std::fabs(normalizedY) < 0.01) normalizedY = 0.0;
    if (normalizedX == 0.0 && normalizedY == 0.0) {
        return NO;
    }

    double scale = std::max(0.1, _config.mouse.rightStickSensitivity) * 12.0;
    double deltaX = normalizedX * scale;
    double deltaY = normalizedY * scale;

    state.lastMouseIntentAt = CFAbsoluteTimeGetCurrent();
    [self moveCursorByDeltaX:deltaX deltaY:deltaY];
    return YES;
}

- (void)performPressAction:(const BindingAction&)action down:(BOOL)down keyboardEnabled:(BOOL)keyboardEnabled mouseEnabled:(BOOL)mouseEnabled {
    switch (action.kind) {
        case BindingActionKindKey:
            if (keyboardEnabled) {
                [self postKeyboardEventForKeyCode:action.keyCode down:down];
            }
            break;
        case BindingActionKindMouseButton:
            if (mouseEnabled) {
                [self postMouseButton:action.mouseButton down:down];
            }
            break;
        case BindingActionKindScroll:
            if (mouseEnabled && down) {
                [self postScrollX:action.scrollX scrollY:action.scrollY];
            }
            break;
        case BindingActionKindGamepadButton:
            [self setupGamepadDeviceIfNeeded];
            [self setGamepadButtonMask:action.gamepadButtonMask down:down];
            break;
        case BindingActionKindGamepadDpad:
            [self setupGamepadDeviceIfNeeded];
            [self setGamepadDpadDirection:action.gamepadDpadDirection down:down];
            break;
        case BindingActionKindLaunchpad:
            if (down) {
                [self openLaunchpad];
            }
            break;
        case BindingActionKindOpenURL:
            if (down) {
                [self openURLString:action.url];
            }
            break;
        case BindingActionKindOpenApp:
            if (down) {
                [self openApplicationTarget:action.url];
            }
            break;
        case BindingActionKindRunShellCommand:
            if (down) {
                [self runShellCommandString:action.url];
            }
            break;
        case BindingActionKindOpenFile:
            if (down) {
                [self openFilePath:action.url withApplication:action.auxiliary];
            }
            break;
        case BindingActionKindMacro:
            if (action.macroKind == BindingMacroKindSpaceClick || action.macroKind == BindingMacroKindShiftDelete) {
                [self performComboMacro:action.macroKind down:down keyboardEnabled:keyboardEnabled mouseEnabled:mouseEnabled];
            } else if (down) {
                [self runMacro:action.macroKind];
            }
            break;
        case BindingActionKindScreenshot:
        case BindingActionKindNone:
        default:
            break;
    }
}

- (void)performTapAction:(const BindingAction&)action keyboardEnabled:(BOOL)keyboardEnabled mouseEnabled:(BOOL)mouseEnabled {
    switch (action.kind) {
        case BindingActionKindKey:
            if (keyboardEnabled) {
                [self postKeyboardEventForKeyCode:action.keyCode down:YES];
                [self postKeyboardEventForKeyCode:action.keyCode down:NO];
            }
            break;
        case BindingActionKindMouseButton:
            if (mouseEnabled) {
                [self postMouseButton:action.mouseButton down:YES];
                [self postMouseButton:action.mouseButton down:NO];
            }
            break;
        case BindingActionKindScroll:
            if (mouseEnabled) {
                [self postScrollX:action.scrollX scrollY:action.scrollY];
            }
            break;
        case BindingActionKindGamepadButton:
            [self setupGamepadDeviceIfNeeded];
            [self setGamepadButtonMask:action.gamepadButtonMask down:YES];
            [self setGamepadButtonMask:action.gamepadButtonMask down:NO];
            break;
        case BindingActionKindGamepadDpad:
            [self setupGamepadDeviceIfNeeded];
            [self setGamepadDpadDirection:action.gamepadDpadDirection down:YES];
            [self setGamepadDpadDirection:action.gamepadDpadDirection down:NO];
            break;
        case BindingActionKindLaunchpad:
            [self openLaunchpad];
            break;
        case BindingActionKindScreenshot:
            [self takeScreenshot];
            break;
        case BindingActionKindOpenURL:
            [self openURLString:action.url];
            break;
        case BindingActionKindOpenApp:
            [self openApplicationTarget:action.url];
            break;
        case BindingActionKindRunShellCommand:
            [self runShellCommandString:action.url];
            break;
        case BindingActionKindOpenFile:
            [self openFilePath:action.url withApplication:action.auxiliary];
            break;
        case BindingActionKindMacro:
            if (action.macroKind == BindingMacroKindSpaceClick || action.macroKind == BindingMacroKindShiftDelete) {
                [self performComboMacro:action.macroKind down:YES keyboardEnabled:keyboardEnabled mouseEnabled:mouseEnabled];
                [self performComboMacro:action.macroKind down:NO keyboardEnabled:keyboardEnabled mouseEnabled:mouseEnabled];
            } else {
                [self runMacro:action.macroKind];
            }
            break;
        case BindingActionKindNone:
        default:
            break;
    }
}

- (void)processButtonBindings:(uint32_t)buttons state:(DeviceState&)state keyboardEnabled:(BOOL)keyboardEnabled mouseEnabled:(BOOL)mouseEnabled {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    const double tapThreshold = 0.30;
    const double tapDebounce = 0.25;
    std::set<uint32_t> relevantMasks;
    for (const auto& entry : _config.bindings) relevantMasks.insert(entry.first);
    switch (self.emulationMode) {
        case MODE_MOUSE:
            for (const auto& entry : _config.mouseBindings) relevantMasks.insert(entry.first);
            break;
        case MODE_KEYBOARD:
            for (const auto& entry : _config.keyboardBindings) relevantMasks.insert(entry.first);
            break;
        case MODE_GAMEPAD:
            for (const auto& entry : _config.gamepadBindings) relevantMasks.insert(entry.first);
            // Gamepad mode also runs the hybrid bindings so mouse scrolling/clicking keeps working.
            for (const auto& entry : _config.hybridBindings) relevantMasks.insert(entry.first);
            break;
        case MODE_HYBRID:
        default:
            for (const auto& entry : _config.hybridBindings) relevantMasks.insert(entry.first);
            break;
    }

    for (uint32_t mask : relevantMasks) {
        const ButtonBinding* binding = [self bindingForMask:mask mode:self.emulationMode];
        const ButtonBinding* hybridBinding = (self.emulationMode == MODE_GAMEPAD) ? [self bindingForMask:mask mode:MODE_HYBRID] : nullptr;
        const ButtonBinding* gamepadBinding = (self.emulationMode == MODE_GAMEPAD) ? [self bindingForMask:mask mode:MODE_GAMEPAD] : nullptr;
        if (!binding && !hybridBinding && !gamepadBinding) {
            continue;
        }
        bool wasPressed = (state.lastButtons & mask) != 0;
        bool isPressed = (buttons & mask) != 0;

        const ButtonBinding* screenshotBinding = nullptr;
        if (hybridBinding && hybridBinding->pressAction.kind == BindingActionKindScreenshot) {
            screenshotBinding = hybridBinding;
        } else if (gamepadBinding && gamepadBinding->pressAction.kind == BindingActionKindScreenshot) {
            screenshotBinding = gamepadBinding;
        } else if (binding && binding->pressAction.kind == BindingActionKindScreenshot) {
            screenshotBinding = binding;
        }

        if (screenshotBinding) {
            if ([self isScreenRecordingActive]) {
                if (isPressed && !wasPressed) {
                    [self stopScreenRecording];
                    state.screenshotHoldTriggered = true;
                } else if (!isPressed && wasPressed) {
                    state.screenshotPressedAt = 0.0;
                    state.screenshotHoldTriggered = false;
                }
                continue;
            }

            if (isPressed && !wasPressed) {
                state.screenshotPressedAt = now;
                state.screenshotHoldTriggered = false;
            } else if (isPressed && wasPressed) {
                if (!state.screenshotHoldTriggered && (now - state.screenshotPressedAt) >= 1.0) {
                    [self startScreenRecording];
                    state.screenshotHoldTriggered = true;
                }
            } else if (!isPressed && wasPressed) {
                if (!state.screenshotHoldTriggered) {
                    [self takeScreenshot];
                }
                state.screenshotPressedAt = 0.0;
                state.screenshotHoldTriggered = false;
            }
            continue;
        }

        if (wasPressed == isPressed) {
            continue;
        }

        if (isPressed) {
            state.buttonPressedAt[mask] = now;
            auto performPressOrTapOnPress = [&](const ButtonBinding* b) {
                if (!b) return;
                if (b->pressAction.kind != BindingActionKindNone) {
                    [self performPressAction:b->pressAction down:YES keyboardEnabled:keyboardEnabled mouseEnabled:mouseEnabled];
                } else if (b->tapAction.kind != BindingActionKindNone) {
                    auto lastTapIt = state.lastTapActionAt.find(mask);
                    double elapsedSinceLastTap = (lastTapIt != state.lastTapActionAt.end()) ? (now - lastTapIt->second) : 999.0;
                    double requiredDebounce = (mask == 0x00080000 && b->tapAction.kind == BindingActionKindMacro &&
                                               b->tapAction.macroKind == BindingMacroKindDoubleW) ? 2.0 : tapDebounce;
                    if (elapsedSinceLastTap >= requiredDebounce) {
                        [self performTapAction:b->tapAction keyboardEnabled:keyboardEnabled mouseEnabled:mouseEnabled];
                        state.lastTapActionAt[mask] = now;
                    }
                }
            };

            if (self.emulationMode == MODE_GAMEPAD) {
                // Run hybrid outputs and gamepad outputs side-by-side.
                performPressOrTapOnPress(hybridBinding);
                performPressOrTapOnPress(gamepadBinding);
            } else if (binding) {
                performPressOrTapOnPress(binding);
            }
        } else {
            auto performRelease = [&](const ButtonBinding* b) {
                if (!b) return;
                if (b->pressAction.kind != BindingActionKindNone) {
                    [self performPressAction:b->pressAction down:NO keyboardEnabled:keyboardEnabled mouseEnabled:mouseEnabled];
                }
            };

            if (self.emulationMode == MODE_GAMEPAD) {
                performRelease(hybridBinding);
                performRelease(gamepadBinding);
            } else if (binding) {
                performRelease(binding);
            }

            auto it = state.buttonPressedAt.find(mask);
            double duration = (it != state.buttonPressedAt.end()) ? (now - it->second) : 0.0;
            auto maybeTapOnRelease = [&](const ButtonBinding* b) {
                if (!b) return;
                bool shouldTap = (b->tapAction.kind != BindingActionKindNone) &&
                                 (b->pressAction.kind != BindingActionKindNone && duration <= tapThreshold);
                if (!shouldTap) return;
                auto lastTapIt = state.lastTapActionAt.find(mask);
                double elapsedSinceLastTap = (lastTapIt != state.lastTapActionAt.end()) ? (now - lastTapIt->second) : 999.0;
                double requiredDebounce = (mask == 0x00080000 && b->tapAction.kind == BindingActionKindMacro &&
                                           b->tapAction.macroKind == BindingMacroKindDoubleW) ? 2.0 : tapDebounce;
                if (elapsedSinceLastTap >= requiredDebounce) {
                    [self performTapAction:b->tapAction keyboardEnabled:keyboardEnabled mouseEnabled:mouseEnabled];
                    state.lastTapActionAt[mask] = now;
                }
            };

            if (self.emulationMode == MODE_GAMEPAD) {
                maybeTapOnRelease(hybridBinding);
                maybeTapOnRelease(gamepadBinding);
            } else if (binding) {
                maybeTapOnRelease(binding);
            }
            state.buttonPressedAt.erase(mask);
        }
    }

    state.lastButtons = buttons;
}

- (void)processLeftStickFromData:(NSDictionary*)joyconData state:(DeviceState&)state {
    if (_config.keyboard.leftStickMode == "none") {
        return;
    }

    NSNumber* leftStickX = joyconData[@"LeftStickX"];
    NSNumber* leftStickY = joyconData[@"LeftStickY"];
    if (!leftStickX || !leftStickY) {
        return;
    }

    double normalizedX = ([leftStickX doubleValue] - 2047.0) / 2047.0;
    double normalizedY = (2047.0 - [leftStickY doubleValue]) / 2047.0;
    double deadzone = ClampDouble(_config.keyboard.stickDeadzone, 0.0, 0.95);

    bool up = normalizedY < -deadzone;
    bool down = normalizedY > deadzone;
    bool left = normalizedX < -deadzone;
    bool right = normalizedX > deadzone;

    CGKeyCode upCode = _config.keyboard.leftStickMode == "arrows" ? 126 : 13;
    CGKeyCode downCode = _config.keyboard.leftStickMode == "arrows" ? 125 : 1;
    CGKeyCode leftCode = _config.keyboard.leftStickMode == "arrows" ? 123 : 0;
    CGKeyCode rightCode = _config.keyboard.leftStickMode == "arrows" ? 124 : 2;

    if (state.stickUp != up) [self postKeyboardEventForKeyCode:upCode down:up];
    if (state.stickDown != down) [self postKeyboardEventForKeyCode:downCode down:down];
    if (state.stickLeft != left) [self postKeyboardEventForKeyCode:leftCode down:left];
    if (state.stickRight != right) [self postKeyboardEventForKeyCode:rightCode down:right];

    state.stickUp = up;
    state.stickDown = down;
    state.stickLeft = left;
    state.stickRight = right;
}

- (void)postKeyboardEventForKeyCode:(CGKeyCode)keyCode down:(BOOL)down {
    CGEventRef event = CGEventCreateKeyboardEvent(NULL, keyCode, down);
    if (!event) {
        return;
    }
    [self postEventToAllTaps:event];
    CFRelease(event);
}

- (void)postKeyboardTapForKeyCode:(CGKeyCode)keyCode flags:(CGEventFlags)flags {
    CGEventRef downEvent = CGEventCreateKeyboardEvent(NULL, keyCode, YES);
    CGEventRef upEvent = CGEventCreateKeyboardEvent(NULL, keyCode, NO);
    if (!downEvent || !upEvent) {
        if (downEvent) CFRelease(downEvent);
        if (upEvent) CFRelease(upEvent);
        return;
    }
    CGEventSetFlags(downEvent, flags);
    CGEventSetFlags(upEvent, flags);
    [self postEventToAllTaps:downEvent];
    [self postEventToAllTaps:upEvent];
    CFRelease(downEvent);
    CFRelease(upEvent);
}

- (void)postMouseButton:(CGMouseButton)button down:(BOOL)down {
    if (button == kCGMouseButtonLeft) {
        _leftMouseHeld = down;
    } else if (button == kCGMouseButtonRight) {
        _rightMouseHeld = down;
    } else {
        _middleMouseHeld = down;
    }

    CGPoint currentPos = _cursorPosition;
    if (CGCursorIsVisible() || !_hasCursorPosition) {
        CGEventRef tempEvent = CGEventCreate(NULL);
        currentPos = CGEventGetLocation(tempEvent);
        CFRelease(tempEvent);
        _cursorPosition = currentPos;
        _hasCursorPosition = YES;
    }

    CGEventType eventType = kCGEventLeftMouseDown;
    if (button == kCGMouseButtonLeft) {
        eventType = down ? kCGEventLeftMouseDown : kCGEventLeftMouseUp;
    } else if (button == kCGMouseButtonRight) {
        eventType = down ? kCGEventRightMouseDown : kCGEventRightMouseUp;
    } else {
        eventType = down ? kCGEventOtherMouseDown : kCGEventOtherMouseUp;
    }

    CGEventRef clickEvent = CGEventCreateMouseEvent(_eventSource, eventType, currentPos, button);
    if (!clickEvent) {
        return;
    }
    CGEventSetIntegerValueField(clickEvent, kCGMouseEventClickState, 1);
    [self postEventToAllTaps:clickEvent];
    CFRelease(clickEvent);
}

- (void)postScrollX:(int32_t)scrollX scrollY:(int32_t)scrollY {
    if (scrollX == 0 && scrollY == 0) {
        return;
    }

    CGEventRef wheelEvent = CGEventCreateScrollWheelEvent(_eventSource, kCGScrollEventUnitLine, 2, scrollY, scrollX);
    if (!wheelEvent) {
        return;
    }
    [self postEventToAllTaps:wheelEvent];
    CFRelease(wheelEvent);
}

@end
