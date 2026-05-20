#import <AppKit/AppKit.h>
#import <ServiceManagement/ServiceManagement.h>

#import "../include/Joycon2BLEReceiver.h"
#import "../include/Joycon2VirtualHID.h"

static NSInteger const kJoyConConfigVersion = 4;

static NSArray<NSString*>* ButtonOrder(void) {
    static NSArray<NSString*>* buttons = nil;
    if (!buttons) {
        buttons = [[NSArray alloc] initWithObjects:
                   @"A", @"B", @"X", @"Y", @"L", @"ZL", @"R", @"ZR",
                   @"UP", @"DOWN", @"LEFT", @"RIGHT",
                   @"SL(L)", @"SR(L)", @"SL(R)", @"SR(R)",
                   @"LS", @"RS", @"SELECT", @"START", @"HOME", @"CAMERA", @"CHAT", nil];
    }
    return buttons;
}

static NSDictionary<NSString*, NSNumber*>* ButtonMaskMapForApp(void) {
    static NSDictionary<NSString*, NSNumber*>* masks = nil;
    if (!masks) {
        masks = [[NSDictionary alloc] initWithObjectsAndKeys:
                 @(0x00000800), @"A",
                 @(0x00000400), @"B",
                 @(0x00000200), @"X",
                 @(0x00000100), @"Y",
                 @(0x40000000), @"L",
                 @(0x80000000), @"ZL",
                 @(0x00004000), @"R",
                 @(0x00008000), @"ZR",
                 @(0x02000000), @"UP",
                 @(0x01000000), @"DOWN",
                 @(0x08000000), @"LEFT",
                 @(0x04000000), @"RIGHT",
                 @(0x20000000), @"SL(L)",
                 @(0x10000000), @"SR(L)",
                 @(0x00002000), @"SL(R)",
                 @(0x00001000), @"SR(R)",
                 @(0x00080000), @"LS",
                 @(0x00040000), @"RS",
                 @(0x00010000), @"SELECT",
                 @(0x00020000), @"START",
                 @(0x00100000), @"HOME",
                 @(0x00200000), @"CAMERA",
                 @(0x00400000), @"CHAT",
                 nil];
    }
    return masks;
}

static NSDictionary<NSString*, NSString*>* ButtonDisplayNames(void) {
    static NSDictionary<NSString*, NSString*>* names = nil;
    if (!names) {
        names = [[NSDictionary alloc] initWithObjectsAndKeys:
                 @"A", @"A",
                 @"B", @"B",
                 @"X", @"X",
                 @"Y", @"Y",
                 @"L", @"L",
                 @"ZL", @"ZL",
                 @"R", @"R",
                 @"ZR", @"ZR",
                 @"D-Pad Up", @"UP",
                 @"D-Pad Down", @"DOWN",
                 @"D-Pad Left", @"LEFT",
                 @"D-Pad Right", @"RIGHT",
                 @"SL Left", @"SL(L)",
                 @"SR Left", @"SR(L)",
                 @"SL Right", @"SL(R)",
                 @"SR Right", @"SR(R)",
                 @"Left Stick Press", @"LS",
                 @"Right Stick Press", @"RS",
                 @"Minus", @"SELECT",
                 @"Plus", @"START",
                 @"Home", @"HOME",
                 @"Capture", @"CAMERA",
                 @"GameChat", @"CHAT",
                 nil];
    }
    return names;
}

static NSDictionary<NSNumber*, NSString*>* KeyNamesByCode(void) {
    static NSDictionary<NSNumber*, NSString*>* names = nil;
    if (!names) {
        names = [[NSDictionary alloc] initWithObjectsAndKeys:
                 @"a", @0, @"s", @1, @"d", @2, @"f", @3, @"h", @4, @"g", @5, @"z", @6, @"x", @7,
                 @"c", @8, @"v", @9, @"b", @11, @"q", @12, @"w", @13, @"e", @14, @"r", @15,
                 @"y", @16, @"t", @17, @"1", @18, @"2", @19, @"3", @20, @"4", @21, @"6", @22,
                 @"5", @23, @"equal", @24, @"9", @25, @"7", @26, @"minus", @27, @"8", @28,
                 @"0", @29, @"right_bracket", @30, @"o", @31, @"u", @32, @"left_bracket", @33,
                 @"i", @34, @"p", @35, @"return", @36, @"l", @37, @"j", @38, @"quote", @39,
                 @"k", @40, @"semicolon", @41, @"backslash", @42, @"comma", @43, @"slash", @44,
                 @"n", @45, @"m", @46, @"period", @47, @"tab", @48, @"space", @49, @"grave", @50,
                 @"delete", @51, @"escape", @53, @"left_command", @55, @"left_shift", @56,
                 @"caps_lock", @57, @"left_option", @58, @"left_control", @59, @"right_shift", @60,
                 @"right_option", @61, @"right_control", @62, @"left_arrow", @123,
                 @"right_arrow", @124, @"down_arrow", @125, @"up_arrow", @126,
                 @"f1", @122, @"f2", @120, @"f3", @99, @"f4", @118, @"f5", @96,
                 nil];
    }
    return names;
}

static NSString* FriendlyActionString(NSString* action) {
    if (![action isKindOfClass:[NSString class]]) {
        return @"";
    }
    NSDictionary* friendly = @{
        @"key:space": @"Space",
        @"key:left_shift": @"Shift",
        @"key:delete": @"Delete",
        @"key:e": @"Inventory",
        @"key:f": @"Use / Interact",
        @"key:g": @"Emote",
        @"key:t": @"Chat",
        @"key:q": @"Drop Item",
        @"key:f5": @"Change POV",
        @"key:escape": @"Escape",
        @"mouse:left": @"Mouse Left Click",
        @"mouse:right": @"Mouse Right Click",
        @"mouse:middle": @"Mouse Middle Click",
        @"mouse:scroll_up": @"Scroll Up",
        @"mouse:scroll_down": @"Scroll Down",
        @"mouse:scroll_left": @"Scroll Left",
        @"mouse:scroll_right": @"Scroll Right",
        @"system:launchpad": @"Launchpad",
        @"system:screenshot": @"Screenshot / Record",
        @"system:discord": @"Open Discord",
        @"system:space_click": @"Space + Left Click",
        @"system:shift_delete": @"Shift + Delete"
    };
    NSString* exact = friendly[action];
    if (exact) {
        return exact;
    }
    if ([action hasPrefix:@"app:"]) {
        return [NSString stringWithFormat:@"Open App: %@", [action substringFromIndex:4]];
    }
    if ([action hasPrefix:@"shell:"]) {
        return [NSString stringWithFormat:@"Run Command: %@", [action substringFromIndex:6]];
    }
    if ([action hasPrefix:@"file_with:"]) {
        NSString* payload = [action substringFromIndex:10];
        NSArray<NSString*>* parts = [payload componentsSeparatedByString:@"\t"];
        NSString* filePart = parts.count > 0 ? [parts[0] lastPathComponent] : payload;
        NSString* appPart = parts.count > 1 ? [parts[1] lastPathComponent] : @"chosen app";
        return [NSString stringWithFormat:@"Open %@ With %@", filePart, appPart];
    }
    if ([action hasPrefix:@"file:"]) {
        return [NSString stringWithFormat:@"Open File: %@", [[action substringFromIndex:5] lastPathComponent]];
    }
    return action;
}

static NSString* BindingSummaryFromValue(id value) {
    if ([value isKindOfClass:[NSString class]]) {
        return [NSString stringWithFormat:@"Hold: %@", FriendlyActionString(value)];
    }
    if (![value isKindOfClass:[NSDictionary class]]) {
        return @"Not set";
    }

    NSMutableArray<NSString*>* parts = [NSMutableArray array];
    NSString* press = value[@"press"] ?: value[@"hold"];
    NSString* tap = value[@"tap"] ?: value[@"click"];
    if (press.length > 0) {
        [parts addObject:[NSString stringWithFormat:@"Hold: %@", FriendlyActionString(press)]];
    }
    if (tap.length > 0) {
        [parts addObject:[NSString stringWithFormat:@"Tap: %@", FriendlyActionString(tap)]];
    }
    return parts.count > 0 ? [parts componentsJoinedByString:@" | "] : @"Not set";
}

@interface Joycon2AppDelegate : NSObject <NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate>
@property (strong, nonatomic) NSWindow* window;
@property (strong, nonatomic) NSTextField* titleLabel;
@property (strong, nonatomic) NSTextField* statusLabel;
@property (strong, nonatomic) NSButton* toggleButton;
@property (strong, nonatomic) NSTextField* configPathLabel;
@property (strong, nonatomic) NSTextField* mouseSensitivityField;
@property (strong, nonatomic) NSTextField* rightStickSensitivityField;
@property (strong, nonatomic) NSTableView* bindingsTable;
@property (strong, nonatomic) Joycon2BLEReceiver* receiver;
@property (strong, nonatomic) Joycon2VirtualHID* hid;
@property (strong, nonatomic) NSStatusItem* statusItem;
@property (copy, nonatomic) NSString* configPath;
@property (strong, nonatomic) NSMutableSet* activeControllers;
@property (strong, nonatomic) NSMutableDictionary* configDocument;
@property (strong, nonatomic) NSMutableDictionary* lastButtonsByController;
@property (strong, nonatomic) NSMutableDictionary* batteryStatusBySide;
@property (copy, nonatomic) NSString* pendingButtonName;
@property (assign, nonatomic) BOOL awaitingJoyConButton;
@property (assign, nonatomic) BOOL running;
@end

@implementation Joycon2AppDelegate

- (BOOL)isRunningFromApplicationsFolder {
    NSString* bundlePath = [[NSBundle mainBundle] bundlePath];
    return [bundlePath hasPrefix:@"/Applications/"];
}

- (void)relaunchFromPath:(NSString*)appPath {
    if (appPath.length == 0) {
        return;
    }
    NSTask* task = [[[NSTask alloc] init] autorelease];
    task.launchPath = @"/usr/bin/open";
    task.arguments = @[appPath];
    @try {
        [task launch];
    } @catch (NSException* exception) {
        NSLog(@"Failed to relaunch app: %@", exception);
    }
}

- (BOOL)promptToMoveToApplicationsIfNeeded {
    if ([self isRunningFromApplicationsFolder]) {
        return NO;
    }

    NSString* bundlePath = [[NSBundle mainBundle] bundlePath];
    NSString* destinationPath = [@"/Applications" stringByAppendingPathComponent:[bundlePath lastPathComponent]];

    NSAlert* alert = [[[NSAlert alloc] init] autorelease];
    alert.messageText = @"Move JoyCon2forMac to Applications?";
    alert.informativeText = @"To run correctly and avoid duplicates in Launchpad, JoyCon2forMac should be installed in /Applications. Click “Move to Applications” to copy it there and relaunch.";
    [alert addButtonWithTitle:@"Move to Applications"];
    [alert addButtonWithTitle:@"Quit"];
    [alert addButtonWithTitle:@"Run From Here"];

    NSModalResponse response = [alert runModal];
    if (response == NSAlertSecondButtonReturn) {
        [NSApp terminate:nil];
        return YES;
    }
    if (response == NSAlertThirdButtonReturn) {
        return NO;
    }

    NSError* error = nil;
    NSFileManager* fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:destinationPath]) {
        if (![fm removeItemAtPath:destinationPath error:&error]) {
            NSLog(@"Failed to remove existing app at %@: %@", destinationPath, error);
            return NO;
        }
    }
    error = nil;
    if (![fm copyItemAtPath:bundlePath toPath:destinationPath error:&error]) {
        NSLog(@"Failed to copy app to %@: %@", destinationPath, error);
        return NO;
    }

    [self relaunchFromPath:destinationPath];
    [NSApp terminate:nil];
    return YES;
}

- (void)enableLaunchAtLoginIfPossible {
    if (@available(macOS 13.0, *)) {
        SMAppService* service = [SMAppService mainAppService];
        if (service.status == SMAppServiceStatusEnabled || service.status == SMAppServiceStatusRequiresApproval) {
            return;
        }

        NSError* error = nil;
        if (![service registerAndReturnError:&error] && error) {
            NSLog(@"Launch-at-login registration failed: %@", error);
        }
    }
}

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
    if ([self promptToMoveToApplicationsIfNeeded]) {
        return;
    }
    [self prepareConfig];
    [self loadConfigDocument];
    [self setupMainMenu];
    [self setupStatusItem];
    [self buildWindow];
    [self startController];
    [self enableLaunchAtLoginIfPossible];
    [self enterBackgroundMode];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender {
    return NO;
}

- (void)applicationWillTerminate:(NSNotification*)notification {
    [self.hid stopEmulation];
}

- (void)prepareConfig {
    NSString* appSupportDir = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
    NSString* projectDir = [appSupportDir stringByAppendingPathComponent:@"JoyCon2forMac"];
    [[NSFileManager defaultManager] createDirectoryAtPath:projectDir withIntermediateDirectories:YES attributes:nil error:nil];

    self.configPath = [projectDir stringByAppendingPathComponent:@"joycon2_config.json"];
    NSString* bundledConfig = [[NSBundle mainBundle] pathForResource:@"joycon2_config" ofType:@"json"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:self.configPath]) {
        if (bundledConfig) {
            [[NSFileManager defaultManager] copyItemAtPath:bundledConfig toPath:self.configPath error:nil];
        }
        return;
    }

    NSData* existingData = [NSData dataWithContentsOfFile:self.configPath];
    NSDictionary* existingConfig = existingData ? [NSJSONSerialization JSONObjectWithData:existingData options:0 error:nil] : nil;
    NSInteger existingVersion = [[existingConfig objectForKey:@"configVersion"] integerValue];
    if (existingVersion >= kJoyConConfigVersion || !bundledConfig) {
        return;
    }

    NSString* backupPath = [projectDir stringByAppendingPathComponent:@"joycon2_config.backup.json"];
    [[NSFileManager defaultManager] removeItemAtPath:backupPath error:nil];
    [[NSFileManager defaultManager] copyItemAtPath:self.configPath toPath:backupPath error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:self.configPath error:nil];
    [[NSFileManager defaultManager] copyItemAtPath:bundledConfig toPath:self.configPath error:nil];
}

- (NSString*)currentModeKey {
    NSString* mode = self.configDocument[@"mode"];
    if ([mode isKindOfClass:[NSString class]] && mode.length > 0) {
        return mode;
    }
    return @"gamepad";
}

- (void)loadConfigDocument {
    NSData* data = [NSData dataWithContentsOfFile:self.configPath];
    NSDictionary* parsed = data ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil] : nil;
    if (![parsed isKindOfClass:[NSDictionary class]]) {
        parsed = [NSMutableDictionary dictionary];
    }
    self.configDocument = [NSMutableDictionary dictionaryWithDictionary:parsed];
    self.configDocument[@"configVersion"] = @(kJoyConConfigVersion);
    if (![self.configDocument[@"modeBindings"] isKindOfClass:[NSDictionary class]]) {
        self.configDocument[@"modeBindings"] = [NSMutableDictionary dictionary];
    }
    [self refreshSensitivityControls];
}

- (void)setConfigModeAndRestartIfNeeded:(NSString*)modeKey {
    if (modeKey.length == 0) {
        return;
    }
    NSString* current = [self currentModeKey];
    if ([current isEqualToString:modeKey]) {
        return;
    }
    self.configDocument[@"mode"] = modeKey;
    [self saveConfigDocumentAndRestartIfNeeded];
}

- (NSInteger)estimatedBatteryPercentFromVoltage:(double)voltage {
    double normalized = (voltage - 3.2) / 0.95;
    NSInteger percent = (NSInteger)llround(fmax(0.0, fmin(1.0, normalized)) * 100.0);
    return percent;
}

- (NSString*)composeLiveStatusForControllerLabel:(NSString*)controllerLabel {
    NSMutableArray<NSString*>* batteryParts = [NSMutableArray array];
    NSString* leftBattery = self.batteryStatusBySide[@"Left"];
    NSString* rightBattery = self.batteryStatusBySide[@"Right"];
    if (leftBattery.length > 0) {
        [batteryParts addObject:[NSString stringWithFormat:@"L %@", leftBattery]];
    }
    if (rightBattery.length > 0) {
        [batteryParts addObject:[NSString stringWithFormat:@"R %@", rightBattery]];
    }
    if (batteryParts.count == 0) {
        return [NSString stringWithFormat:@"Status: receiving input from %@", controllerLabel];
    }
    return [NSString stringWithFormat:@"Status: receiving input from %@ | Battery: %@", controllerLabel, [batteryParts componentsJoinedByString:@"  "]];
}

- (NSMutableDictionary*)mutableModeBindingsForCurrentMode {
    NSMutableDictionary* modeBindings = self.configDocument[@"modeBindings"];
    if (![modeBindings isKindOfClass:[NSMutableDictionary class]]) {
        modeBindings = [NSMutableDictionary dictionaryWithDictionary:modeBindings ?: @{}];
        self.configDocument[@"modeBindings"] = modeBindings;
    }

    NSString* modeKey = [self currentModeKey];
    id current = modeBindings[modeKey];
    if (![current isKindOfClass:[NSDictionary class]]) {
        current = [NSMutableDictionary dictionary];
        modeBindings[modeKey] = current;
    } else if (![current isKindOfClass:[NSMutableDictionary class]]) {
        current = [NSMutableDictionary dictionaryWithDictionary:current];
        modeBindings[modeKey] = current;
    }
    return (NSMutableDictionary*)current;
}

- (NSMutableDictionary*)mutableMouseConfig {
    id mouse = self.configDocument[@"mouse"];
    if (![mouse isKindOfClass:[NSDictionary class]]) {
        mouse = [NSMutableDictionary dictionary];
        self.configDocument[@"mouse"] = mouse;
    } else if (![mouse isKindOfClass:[NSMutableDictionary class]]) {
        mouse = [NSMutableDictionary dictionaryWithDictionary:mouse];
        self.configDocument[@"mouse"] = mouse;
    }
    return (NSMutableDictionary*)mouse;
}

- (double)configuredMouseSensitivity {
    NSNumber* value = [self mutableMouseConfig][@"sensitivity"];
    return [value isKindOfClass:[NSNumber class]] ? [value doubleValue] : 0.35;
}

- (double)configuredRightStickSensitivity {
    NSMutableDictionary* mouse = [self mutableMouseConfig];
    NSNumber* value = mouse[@"rightStickSensitivity"];
    if ([value isKindOfClass:[NSNumber class]]) {
        return [value doubleValue];
    }
    NSNumber* fallback = mouse[@"sensitivity"];
    return [fallback isKindOfClass:[NSNumber class]] ? [fallback doubleValue] : 0.35;
}

- (void)refreshSensitivityControls {
    if (!self.mouseSensitivityField || !self.rightStickSensitivityField) {
        return;
    }
    self.mouseSensitivityField.stringValue = [NSString stringWithFormat:@"%.2f", [self configuredMouseSensitivity]];
    self.rightStickSensitivityField.stringValue = [NSString stringWithFormat:@"%.2f", [self configuredRightStickSensitivity]];
}

- (void)buildWindow {
    if (self.window) {
        return;
    }

    NSRect frame = NSMakeRect(0, 0, 820, 640);
    self.window = [[NSWindow alloc] initWithContentRect:frame
                                              styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable)
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    [self.window center];
    [self.window setTitle:@"JoyCon2 for Mac"];
    [self.window setDelegate:self];

    NSView* contentView = self.window.contentView;

    self.titleLabel = [self labelWithFrame:NSMakeRect(24, 592, 760, 28)
                                      text:@"Joy-Con 2 mapping for macOS"
                                      font:[NSFont boldSystemFontOfSize:20]];
    [contentView addSubview:self.titleLabel];

    self.statusLabel = [self labelWithFrame:NSMakeRect(24, 560, 760, 22)
                                       text:@"Status: starting"
                                       font:[NSFont systemFontOfSize:13]];
    [contentView addSubview:self.statusLabel];

    self.toggleButton = [[NSButton alloc] initWithFrame:NSMakeRect(24, 516, 120, 32)];
    [self.toggleButton setBezelStyle:NSBezelStyleRounded];
    [self.toggleButton setTitle:@"Stop"];
    [self.toggleButton setTarget:self];
    [self.toggleButton setAction:@selector(toggleRunning:)];
    [contentView addSubview:self.toggleButton];

    NSButton* mapButton = [[NSButton alloc] initWithFrame:NSMakeRect(158, 516, 170, 30)];
    [mapButton setBezelStyle:NSBezelStyleRounded];
    [mapButton setTitle:@"Map Joy-Con Button"];
    [mapButton setTarget:self];
    [mapButton setAction:@selector(beginMappingFlow:)];
    [contentView addSubview:mapButton];

    NSButton* resetButton = [[NSButton alloc] initWithFrame:NSMakeRect(342, 516, 130, 30)];
    [resetButton setBezelStyle:NSBezelStyleRounded];
    [resetButton setTitle:@"Restore Defaults"];
    [resetButton setTarget:self];
    [resetButton setAction:@selector(restoreDefaults:)];
    [contentView addSubview:resetButton];

    NSButton* openConfigButton = [[NSButton alloc] initWithFrame:NSMakeRect(486, 516, 150, 30)];
    [openConfigButton setBezelStyle:NSBezelStyleRounded];
    [openConfigButton setTitle:@"Open Config Folder"];
    [openConfigButton setTarget:self];
    [openConfigButton setAction:@selector(openConfigFolder:)];
    [contentView addSubview:openConfigButton];

    NSTextField* mouseSensitivityLabel = [self labelWithFrame:NSMakeRect(24, 482, 150, 22)
                                                         text:@"Mouse Sensitivity"
                                                         font:[NSFont systemFontOfSize:12]];
    [contentView addSubview:mouseSensitivityLabel];

    self.mouseSensitivityField = [[[NSTextField alloc] initWithFrame:NSMakeRect(176, 478, 80, 24)] autorelease];
    [contentView addSubview:self.mouseSensitivityField];

    NSTextField* rightStickSensitivityLabel = [self labelWithFrame:NSMakeRect(274, 482, 170, 22)
                                                              text:@"Right Stick Sensitivity"
                                                              font:[NSFont systemFontOfSize:12]];
    [contentView addSubview:rightStickSensitivityLabel];

    self.rightStickSensitivityField = [[[NSTextField alloc] initWithFrame:NSMakeRect(444, 478, 80, 24)] autorelease];
    [contentView addSubview:self.rightStickSensitivityField];

    NSButton* applySensitivityButton = [[NSButton alloc] initWithFrame:NSMakeRect(542, 476, 130, 28)];
    [applySensitivityButton setBezelStyle:NSBezelStyleRounded];
    [applySensitivityButton setTitle:@"Apply Sensitivity"];
    [applySensitivityButton setTarget:self];
    [applySensitivityButton setAction:@selector(applySensitivitySettings:)];
    [contentView addSubview:applySensitivityButton];

    self.configPathLabel = [self labelWithFrame:NSMakeRect(24, 438, 760, 32)
                                           text:[NSString stringWithFormat:@"Config: %@", self.configPath]
                                           font:[NSFont systemFontOfSize:11]];
    [self.configPathLabel setLineBreakMode:NSLineBreakByTruncatingMiddle];
    [contentView addSubview:self.configPathLabel];

    NSScrollView* tableScrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(24, 110, 772, 312)];
    [tableScrollView setHasVerticalScroller:YES];
    [tableScrollView setBorderType:NSBezelBorder];

    self.bindingsTable = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 772, 312)];
    NSTableColumn* buttonColumn = [[NSTableColumn alloc] initWithIdentifier:@"button"];
    [buttonColumn setTitle:@"Joy-Con Button"];
    [buttonColumn setWidth:180];
    NSTableColumn* bindingColumn = [[NSTableColumn alloc] initWithIdentifier:@"binding"];
    [bindingColumn setTitle:@"Current Mapping"];
    [bindingColumn setWidth:580];
    [self.bindingsTable addTableColumn:buttonColumn];
    [self.bindingsTable addTableColumn:bindingColumn];
    [self.bindingsTable setDelegate:self];
    [self.bindingsTable setDataSource:self];
    [self.bindingsTable setHeaderView:nil];
    [self.bindingsTable setRowHeight:24.0];
    [tableScrollView setDocumentView:self.bindingsTable];
    [contentView addSubview:tableScrollView];

    NSTextField* controls = [self labelWithFrame:NSMakeRect(24, 24, 772, 68)
                                             text:@"Click “Map Joy-Con Button”, press the controller button you want to change, then choose whether it should use a normal press / hold action or a tap-only action. For a normal press / hold action, a quick tap triggers the same output once and holding the Joy-Con button keeps that output held. Keyboard bindings are learned by pressing the Mac key you want. Mouse actions, system actions, app launches, terminal commands, and file opens come from popups."
                                             font:[NSFont systemFontOfSize:12]];
    [controls setLineBreakMode:NSLineBreakByWordWrapping];
    [controls setUsesSingleLineMode:NO];
    [contentView addSubview:controls];

    [self refreshSensitivityControls];
    [self.bindingsTable reloadData];
}

- (void)setupMainMenu {
    NSString* appName = [[NSProcessInfo processInfo] processName];

    NSMenu* mainMenu = [[NSMenu alloc] initWithTitle:@""];
    NSMenuItem* appMenuItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    [mainMenu addItem:appMenuItem];

    NSMenu* appMenu = [[NSMenu alloc] initWithTitle:appName];
    NSMenuItem* reconfigureItem = [[NSMenuItem alloc] initWithTitle:@"Reconfigure / Remap..."
                                                             action:@selector(showHybridConfigurationWindow:)
                                                      keyEquivalent:@","];
    [reconfigureItem setTarget:self];
    [appMenu addItem:reconfigureItem];
    [reconfigureItem release];

    NSMenuItem* gamepadItem = [[NSMenuItem alloc] initWithTitle:@"Gamepad Controls..."
                                                        action:@selector(showGamepadConfigurationWindow:)
                                                 keyEquivalent:@""];
    [gamepadItem setTarget:self];
    [appMenu addItem:gamepadItem];
    [gamepadItem release];

    NSMenuItem* keyboardItem = [[NSMenuItem alloc] initWithTitle:@"Keyboard Controls..."
                                                         action:@selector(showKeyboardConfigurationWindow:)
                                                  keyEquivalent:@""];
    [keyboardItem setTarget:self];
    [appMenu addItem:keyboardItem];
    [keyboardItem release];

    [appMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem* quitItem = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"Quit %@", appName]
                                                      action:@selector(terminate:)
                                               keyEquivalent:@"q"];
    [appMenu addItem:quitItem];
    [quitItem release];

    [appMenuItem setSubmenu:appMenu];
    [appMenu release];
    [appMenuItem release];

    [NSApp setMainMenu:mainMenu];
    [mainMenu release];
}

- (void)setupStatusItem {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    if (self.statusItem.button) {
        [self.statusItem.button setTitle:@"JoyCon2forMac"];
    }

    NSMenu* statusMenu = [[NSMenu alloc] initWithTitle:@"JoyCon2forMac"];
    NSMenuItem* reconfigureItem = [[NSMenuItem alloc] initWithTitle:@"Reconfigure / Remap..."
                                                             action:@selector(showHybridConfigurationWindow:)
                                                      keyEquivalent:@""];
    [reconfigureItem setTarget:self];
    [statusMenu addItem:reconfigureItem];
    [reconfigureItem release];

    NSMenuItem* gamepadItem = [[NSMenuItem alloc] initWithTitle:@"Gamepad Controls..."
                                                        action:@selector(showGamepadConfigurationWindow:)
                                                 keyEquivalent:@""];
    [gamepadItem setTarget:self];
    [statusMenu addItem:gamepadItem];
    [gamepadItem release];

    NSMenuItem* keyboardItem = [[NSMenuItem alloc] initWithTitle:@"Keyboard Controls..."
                                                         action:@selector(showKeyboardConfigurationWindow:)
                                                  keyEquivalent:@""];
    [keyboardItem setTarget:self];
    [statusMenu addItem:keyboardItem];
    [keyboardItem release];

    [statusMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem* quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit JoyCon2forMac"
                                                      action:@selector(terminate:)
                                               keyEquivalent:@""];
    [statusMenu addItem:quitItem];
    [quitItem release];

    [self.statusItem setMenu:statusMenu];
    [statusMenu release];
}

- (void)enterBackgroundMode {
    [self.window orderOut:nil];
    // Keep running as a menu bar app without a Dock icon.
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
}

- (void)showHybridConfigurationWindow:(id)sender {
    [self setConfigModeAndRestartIfNeeded:@"hybrid"];
    [self showConfigurationWindow:sender];
}

- (void)showGamepadConfigurationWindow:(id)sender {
    [self setConfigModeAndRestartIfNeeded:@"gamepad"];
    [self showConfigurationWindow:sender];
}

- (void)showKeyboardConfigurationWindow:(id)sender {
    [self setConfigModeAndRestartIfNeeded:@"keyboard"];
    [self showConfigurationWindow:sender];
}

- (void)showConfigurationWindow:(id)sender {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [self buildWindow];
    NSString* modeKey = [[self currentModeKey] lowercaseString];
    if ([modeKey isEqualToString:@"gamepad"]) {
        self.titleLabel.stringValue = @"Joy-Con 2 mapping + gamepad for macOS";
    } else if ([modeKey isEqualToString:@"keyboard"]) {
        self.titleLabel.stringValue = @"Joy-Con 2 mapping + keyboard for macOS";
    } else {
        self.titleLabel.stringValue = @"Joy-Con 2 mapping + mouse + keyboard for macOS";
    }
    [self refreshBindingsTable];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication*)sender hasVisibleWindows:(BOOL)flag {
    if (!flag) {
        [self showConfigurationWindow:nil];
    }
    return YES;
}

- (BOOL)windowShouldClose:(id)sender {
    [self enterBackgroundMode];
    return NO;
}

- (NSTextField*)labelWithFrame:(NSRect)frame text:(NSString*)text font:(NSFont*)font {
    NSTextField* label = [[NSTextField alloc] initWithFrame:frame];
    [label setEditable:NO];
    [label setBezeled:NO];
    [label setDrawsBackground:NO];
    [label setStringValue:text ?: @""];
    [label setFont:font];
    return label;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView*)tableView {
    return ButtonOrder().count;
}

- (id)tableView:(NSTableView*)tableView objectValueForTableColumn:(NSTableColumn*)tableColumn row:(NSInteger)row {
    NSString* buttonName = ButtonOrder()[row];
    if ([tableColumn.identifier isEqualToString:@"button"]) {
        return ButtonDisplayNames()[buttonName] ?: buttonName;
    }

    NSDictionary* modeBindings = [self mutableModeBindingsForCurrentMode];
    id value = modeBindings[buttonName];
    return BindingSummaryFromValue(value);
}

- (void)refreshBindingsTable {
    [self.bindingsTable reloadData];
}

- (EmulationMode)selectedMode {
    NSString* modeKey = [self currentModeKey];
    NSString* lower = [[modeKey lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
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

- (void)startController {
    self.activeControllers = [NSMutableSet set];
    self.lastButtonsByController = [NSMutableDictionary dictionary];
    self.batteryStatusBySide = [NSMutableDictionary dictionary];
    self.receiver = [Joycon2BLEReceiver sharedInstance];
    self.hid = [[Joycon2VirtualHID alloc] initWithMode:[self selectedMode] modeOverridden:YES configPath:self.configPath];

    __block Joycon2AppDelegate* weakSelf = self;
    self.receiver.onDeviceFound = ^(NSString* name, NSString* address) {
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.statusLabel.stringValue = [NSString stringWithFormat:@"Status: found %@, connecting", name ?: @"Joy-Con 2"];
        });
    };
    self.receiver.onConnected = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.statusLabel.stringValue = @"Status: Joy-Con connected, waiting for input";
        });
    };
    self.receiver.onDataReceived = ^(NSDictionary* data) {
        if (weakSelf.hid) {
            [weakSelf.hid sendHIDReportFromJoyconData:data];
        }

        NSString* controllerKey = data[@"PeripheralIdentifier"] ?: @"unknown";
        uint32_t buttons = (uint32_t)[data[@"Buttons"] unsignedLongLongValue];
        uint32_t previousButtons = (uint32_t)[weakSelf.lastButtonsByController[controllerKey] unsignedIntValue];
        weakSelf.lastButtonsByController[controllerKey] = @(buttons);

        NSString* deviceType = data[@"DeviceType"] ?: @"Unknown";
        NSNumber* batteryVoltage = data[@"BatteryVoltage"];
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([deviceType isEqualToString:@"L"]) {
                [weakSelf.activeControllers addObject:@"Left"];
                if ([batteryVoltage isKindOfClass:[NSNumber class]]) {
                    NSInteger percent = [weakSelf estimatedBatteryPercentFromVoltage:[batteryVoltage doubleValue]];
                    weakSelf.batteryStatusBySide[@"Left"] = [NSString stringWithFormat:@"%ld%% est", (long)percent];
                }
            } else if ([deviceType isEqualToString:@"R"]) {
                [weakSelf.activeControllers addObject:@"Right"];
                if ([batteryVoltage isKindOfClass:[NSNumber class]]) {
                    NSInteger percent = [weakSelf estimatedBatteryPercentFromVoltage:[batteryVoltage doubleValue]];
                    weakSelf.batteryStatusBySide[@"Right"] = [NSString stringWithFormat:@"%ld%% est", (long)percent];
                }
            }

            NSString* controllerLabel = @"Joy-Con";
            if (weakSelf.activeControllers.count == 2) {
                controllerLabel = @"Left + Right Joy-Con";
            } else if ([weakSelf.activeControllers containsObject:@"Right"]) {
                controllerLabel = @"Right Joy-Con";
            } else if ([weakSelf.activeControllers containsObject:@"Left"]) {
                controllerLabel = @"Left Joy-Con";
            }

            if (weakSelf.awaitingJoyConButton) {
                uint32_t newlyPressed = buttons & ~previousButtons;
                for (NSString* candidate in ButtonOrder()) {
                    uint32_t mask = (uint32_t)[ButtonMaskMapForApp()[candidate] unsignedIntValue];
                    if ((newlyPressed & mask) != 0) {
                        weakSelf.awaitingJoyConButton = NO;
                        weakSelf.pendingButtonName = candidate;
                        weakSelf.statusLabel.stringValue = [NSString stringWithFormat:@"Status: mapping %@", ButtonDisplayNames()[candidate] ?: candidate];
                        [weakSelf runMappingFlowForButton:candidate];
                        return;
                    }
                }
            }

            weakSelf.statusLabel.stringValue = [weakSelf composeLiveStatusForControllerLabel:controllerLabel];
        });
    };
    self.receiver.onError = ^(NSString* error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.statusLabel.stringValue = [NSString stringWithFormat:@"Status: error - %@", error ?: @"unknown"];
        });
    };

    [self.hid startEmulation];
    self.running = YES;
    [self.statusLabel setStringValue:@"Status: scanning for Joy-Con 2 controllers"];
    [self.toggleButton setTitle:@"Stop"];
}

- (void)stopController {
    self.receiver.onDeviceFound = nil;
    self.receiver.onConnected = nil;
    self.receiver.onDataReceived = nil;
    self.receiver.onError = nil;
    [self.hid stopEmulation];
    self.hid = nil;
    self.receiver = nil;
    self.activeControllers = nil;
    self.lastButtonsByController = nil;
    self.batteryStatusBySide = nil;
    self.awaitingJoyConButton = NO;
    self.running = NO;
    [self.statusLabel setStringValue:@"Status: stopped"];
    [self.toggleButton setTitle:@"Start"];
}

- (void)toggleRunning:(id)sender {
    if (self.running) {
        [self stopController];
    } else {
        [self startController];
    }
}

- (void)openConfigFolder:(id)sender {
    [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:self.configPath]]];
}

- (void)restoreDefaults:(id)sender {
    NSString* bundledConfig = [[NSBundle mainBundle] pathForResource:@"joycon2_config" ofType:@"json"];
    if (!bundledConfig) {
        self.statusLabel.stringValue = @"Status: bundled default config not found";
        return;
    }

    [[NSFileManager defaultManager] removeItemAtPath:self.configPath error:nil];
    [[NSFileManager defaultManager] copyItemAtPath:bundledConfig toPath:self.configPath error:nil];
    [self loadConfigDocument];
    [self refreshBindingsTable];
    self.statusLabel.stringValue = @"Status: restored bundled defaults";
    if (self.running) {
        [self stopController];
        [self startController];
    }
}

- (void)beginMappingFlow:(id)sender {
    self.awaitingJoyConButton = YES;
    self.pendingButtonName = nil;
    self.statusLabel.stringValue = @"Status: press the Joy-Con button you want to map";
}

- (NSString*)promptWithTitle:(NSString*)title message:(NSString*)message options:(NSArray<NSString*>*)options {
    NSAlert* alert = [[NSAlert alloc] init];
    [alert setMessageText:title];
    [alert setInformativeText:message ?: @""];
    [alert addButtonWithTitle:@"OK"];
    [alert addButtonWithTitle:@"Cancel"];

    NSPopUpButton* popup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 280, 26) pullsDown:NO];
    [popup addItemsWithTitles:options];
    [alert setAccessoryView:popup];

    NSModalResponse response = [alert runModal];
    NSString* selected = response == NSAlertFirstButtonReturn ? popup.titleOfSelectedItem : nil;
    [popup release];
    [alert release];
    return selected;
}

- (NSString*)keyboardBindingFromCapturedKey {
    NSAlert* alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Press a key on your Mac"];
    [alert setInformativeText:@"The next key you press will be assigned to this Joy-Con button."];
    [alert addButtonWithTitle:@"Cancel"];

    __block NSString* capturedKey = nil;
    id monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent* (NSEvent* event) {
        capturedKey = [KeyNamesByCode() objectForKey:@(event.keyCode)];
        if (capturedKey.length > 0) {
            [NSApp stopModalWithCode:NSModalResponseOK];
            return nil;
        }
        return event;
    }];

    NSModalResponse response = [alert runModal];
    [NSEvent removeMonitor:monitor];
    [alert release];
    if (response != NSModalResponseOK || capturedKey.length == 0) {
        return nil;
    }
    return [NSString stringWithFormat:@"key:%@", capturedKey];
}

- (NSString*)promptForTextWithTitle:(NSString*)title message:(NSString*)message defaultValue:(NSString*)defaultValue {
    NSAlert* alert = [[NSAlert alloc] init];
    [alert setMessageText:title];
    [alert setInformativeText:message ?: @""];
    [alert addButtonWithTitle:@"OK"];
    [alert addButtonWithTitle:@"Cancel"];

    NSTextField* field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 320, 24)];
    [field setStringValue:defaultValue ?: @""];
    [alert setAccessoryView:field];

    NSModalResponse response = [alert runModal];
    NSString* value = response == NSAlertFirstButtonReturn ? [[field stringValue] copy] : nil;
    [field release];
    [alert release];
    return [value autorelease];
}

- (NSString*)chooseApplicationTarget {
    NSString* choice = [self promptWithTitle:@"Choose App Source"
                                     message:@"Choose an installed app bundle or type an app name / path."
                                     options:@[@"Choose App Bundle", @"Type App Name or Path"]];
    if (!choice) {
        return nil;
    }
    if ([choice isEqualToString:@"Type App Name or Path"]) {
        return [self promptForTextWithTitle:@"App Name or Path"
                                    message:@"Enter an app name like Safari or a full path to an .app bundle."
                               defaultValue:@""];
    }

    NSOpenPanel* panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = YES;
    panel.allowsMultipleSelection = NO;
    panel.canCreateDirectories = NO;
    panel.allowedFileTypes = @[@"app"];
    NSModalResponse response = [panel runModal];
    if (response != NSModalResponseOK) {
        return nil;
    }
    return panel.URL.path;
}

- (NSString*)chooseFileTargetPath {
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = YES;
    panel.allowsMultipleSelection = NO;
    panel.canCreateDirectories = NO;
    NSModalResponse response = [panel runModal];
    if (response != NSModalResponseOK) {
        return nil;
    }
    return panel.URL.path;
}

- (NSString*)promptForActionWithPrompt:(NSString*)prompt {
    NSString* category = [self promptWithTitle:@"Choose Output Type"
                                       message:prompt
                                       options:@[@"Keyboard Key", @"Mouse Action", @"Gamepad Action", @"System Action", @"Open App", @"Run Terminal Command", @"Open File", @"Clear Binding"]];
    if (!category) {
        return nil;
    }
    if ([category isEqualToString:@"Clear Binding"]) {
        return @"";
    }
    if ([category isEqualToString:@"Keyboard Key"]) {
        return [self keyboardBindingFromCapturedKey];
    }
    if ([category isEqualToString:@"Open App"]) {
        NSString* appTarget = [self chooseApplicationTarget];
        return appTarget.length > 0 ? [NSString stringWithFormat:@"app:%@", appTarget] : nil;
    }
    if ([category isEqualToString:@"Run Terminal Command"]) {
        NSString* command = [self promptForTextWithTitle:@"Terminal Command"
                                                 message:@"Enter the shell command to run when this Joy-Con button is used."
                                            defaultValue:@""];
        return command.length > 0 ? [NSString stringWithFormat:@"shell:%@", command] : nil;
    }
    if ([category isEqualToString:@"Open File"]) {
        NSString* fileTarget = [self chooseFileTargetPath];
        if (fileTarget.length == 0) {
            return nil;
        }
        NSString* fileMode = [self promptWithTitle:@"Choose File Open Mode"
                                           message:@"Open the file with its default app or choose a specific app."
                                           options:@[@"Default App", @"Choose Specific App"]];
        if (!fileMode) {
            return nil;
        }
        if ([fileMode isEqualToString:@"Default App"]) {
            return [NSString stringWithFormat:@"file:%@", fileTarget];
        }
        NSString* appTarget = [self chooseApplicationTarget];
        return appTarget.length > 0 ? [NSString stringWithFormat:@"file_with:%@\t%@", fileTarget, appTarget] : nil;
    }
    if ([category isEqualToString:@"Mouse Action"]) {
        NSDictionary* actionMap = @{
            @"Left Click": @"mouse:left",
            @"Right Click": @"mouse:right",
            @"Middle Click": @"mouse:middle",
            @"Scroll Up": @"mouse:scroll_up",
            @"Scroll Down": @"mouse:scroll_down",
            @"Scroll Left": @"mouse:scroll_left",
            @"Scroll Right": @"mouse:scroll_right"
        };
        NSString* label = [self promptWithTitle:@"Choose Mouse Action"
                                        message:prompt
                                        options:actionMap.allKeys];
        return label ? actionMap[label] : nil;
    }

    if ([category isEqualToString:@"Gamepad Action"]) {
        NSDictionary* gamepadMap = @{
            @"A Button": @"gamepad:a",
            @"B Button": @"gamepad:b",
            @"X Button": @"gamepad:x",
            @"Y Button": @"gamepad:y",
            @"L Button": @"gamepad:l1",
            @"R Button": @"gamepad:r1",
            @"ZL Button": @"gamepad:l2",
            @"ZR Button": @"gamepad:r2",
            @"Minus": @"gamepad:minus",
            @"Plus": @"gamepad:plus",
            @"Left Stick Click": @"gamepad:l3",
            @"Right Stick Click": @"gamepad:r3",
            @"D-Pad Up": @"gamepad:dpad_up",
            @"D-Pad Down": @"gamepad:dpad_down",
            @"D-Pad Left": @"gamepad:dpad_left",
            @"D-Pad Right": @"gamepad:dpad_right"
        };
        NSString* label = [self promptWithTitle:@"Choose Gamepad Action"
                                        message:prompt
                                        options:gamepadMap.allKeys];
        return label ? gamepadMap[label] : nil;
    }

    NSDictionary* systemMap = @{
        @"Launchpad": @"system:launchpad",
        @"Screenshot / Screen Record": @"system:screenshot",
        @"Open Discord": @"system:discord",
        @"Change POV (Fn+F5)": @"system:pov",
        @"Double W": @"system:double_w"
    };
    NSString* label = [self promptWithTitle:@"Choose System Action"
                                    message:prompt
                                    options:systemMap.allKeys];
    return label ? systemMap[label] : nil;
}

- (void)saveConfigDocumentAndRestartIfNeeded {
    self.configDocument[@"configVersion"] = @(kJoyConConfigVersion);
    NSData* data = [NSJSONSerialization dataWithJSONObject:self.configDocument options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToFile:self.configPath atomically:YES];
    [self loadConfigDocument];
    [self refreshSensitivityControls];
    [self refreshBindingsTable];
    if (self.running) {
        [self stopController];
        [self startController];
    }
}

- (void)applySensitivitySettings:(id)sender {
    double mouseSensitivity = [self.mouseSensitivityField doubleValue];
    double rightStickSensitivity = [self.rightStickSensitivityField doubleValue];
    if (mouseSensitivity <= 0.0 || rightStickSensitivity <= 0.0) {
        self.statusLabel.stringValue = @"Status: sensitivity values must be greater than 0";
        [self refreshSensitivityControls];
        return;
    }

    NSMutableDictionary* mouse = [self mutableMouseConfig];
    mouse[@"sensitivity"] = @(mouseSensitivity);
    mouse[@"rightStickSensitivity"] = @(rightStickSensitivity);
    [self saveConfigDocumentAndRestartIfNeeded];
    self.statusLabel.stringValue = [NSString stringWithFormat:@"Status: updated sensitivities (mouse %.2f, right stick %.2f)", mouseSensitivity, rightStickSensitivity];
}

- (void)applyPressAction:(NSString*)pressAction tapAction:(NSString*)tapAction forButton:(NSString*)buttonName {
    NSMutableDictionary* modeBindings = [self mutableModeBindingsForCurrentMode];
    if (pressAction.length == 0 && tapAction.length == 0) {
        [modeBindings removeObjectForKey:buttonName];
    } else if (pressAction.length > 0 && tapAction.length == 0) {
        modeBindings[buttonName] = pressAction;
    } else {
        NSMutableDictionary* entry = [NSMutableDictionary dictionary];
        if (pressAction.length > 0) {
            entry[@"press"] = pressAction;
        }
        if (tapAction.length > 0) {
            entry[@"tap"] = tapAction;
        }
        modeBindings[buttonName] = entry;
    }
    [self saveConfigDocumentAndRestartIfNeeded];
}

- (void)runMappingFlowForButton:(NSString*)buttonName {
    NSString* triggerChoice = [self promptWithTitle:@"Choose Trigger Type"
                                            message:[NSString stringWithFormat:@"Choose how %@ should behave.", ButtonDisplayNames()[buttonName] ?: buttonName]
                                            options:@[@"Press / Hold", @"Tap Only"]];
    if (!triggerChoice) {
        self.statusLabel.stringValue = @"Status: mapping cancelled";
        return;
    }

    NSString* pressAction = nil;
    NSString* tapAction = nil;
    if ([triggerChoice isEqualToString:@"Tap Only"]) {
        tapAction = [self promptForActionWithPrompt:@"Choose what should happen when the Joy-Con button is tapped."];
    } else {
        pressAction = [self promptForActionWithPrompt:@"Choose what should happen when this Joy-Con button is pressed or held. A quick tap will trigger the same output once, while holding the Joy-Con button keeps that output held."];
    }

    if (pressAction == nil && tapAction == nil) {
        self.statusLabel.stringValue = @"Status: mapping cancelled";
        return;
    }

    [self applyPressAction:pressAction tapAction:tapAction forButton:buttonName];
    self.statusLabel.stringValue = [NSString stringWithFormat:@"Status: mapped %@", ButtonDisplayNames()[buttonName] ?: buttonName];
}

@end

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSApplication* app = [NSApplication sharedApplication];
        Joycon2AppDelegate* delegate = [[Joycon2AppDelegate alloc] init];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [app setDelegate:delegate];
        [app run];
    }
    return 0;
}
