#import <Foundation/Foundation.h>
#import <IOKit/hid/IOHIDLib.h>
#import <IOKit/hid/IOHIDKeys.h>
#import <IOKit/IOKitLib.h>
#import <ApplicationServices/ApplicationServices.h>
#ifndef HID_ENABLE
#import "Joycon2BLEReceiver.h"
#endif

typedef enum {
    MODE_HYBRID,
    MODE_MOUSE,
    MODE_KEYBOARD,
    MODE_GAMEPAD
} EmulationMode;

@interface Joycon2VirtualHID : NSObject {
#ifndef HID_ENABLE
    Joycon2BLEReceiver *joyconClient;
#endif
    bool _initialized;
    EmulationMode _emulationMode;
    CFMachPortRef _eventTap;
    BOOL _modeOverridden;
    NSString *_configPath;
}

@property bool initialized;
@property EmulationMode emulationMode;

- (instancetype)initWithMode:(EmulationMode)mode;
- (instancetype)initWithMode:(EmulationMode)mode modeOverridden:(BOOL)modeOverridden configPath:(NSString*)configPath;
- (void)startEmulation;
- (void)stopEmulation;
#ifndef HID_ENABLE
- (void)sendHIDReportFromJoyconData:(NSDictionary *)joyconData;
#endif

@end
