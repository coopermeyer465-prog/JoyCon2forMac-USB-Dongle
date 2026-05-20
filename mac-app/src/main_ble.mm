#import "Joycon2BLEReceiver.h"
#import "Joycon2VirtualHID.h"

int main(int argc, const char * argv[]) {
    EmulationMode mode = MODE_HYBRID;
    bool modeOverridden = false;
    NSString *configPath = nil;

    // Parse command line arguments
    for (int i = 1; i < argc; ++i) {
        if (strcmp(argv[i], "--mouse") == 0) {
            mode = MODE_MOUSE;
            modeOverridden = true;
        } else if (strcmp(argv[i], "--keyboard") == 0) {
            mode = MODE_KEYBOARD;
            modeOverridden = true;
        } else if (strcmp(argv[i], "--hybrid") == 0) {
            mode = MODE_HYBRID;
            modeOverridden = true;
        } else if (strcmp(argv[i], "--config") == 0 && i + 1 < argc) {
            configPath = [NSString stringWithUTF8String:argv[++i]];
        } else {
            fprintf(stderr, "Usage: %s [--mouse | --keyboard | --hybrid] [--config path]\n", argv[0]);
            fprintf(stderr, "  --mouse: Right Joy-Con mouse sensor and mouse bindings only\n");
            fprintf(stderr, "  --keyboard: Keyboard bindings and left-stick keys only\n");
            fprintf(stderr, "  --hybrid: Mouse sensor plus keyboard/mouse bindings (default)\n");
            fprintf(stderr, "  --config path: Use a specific JSON config file\n");
            return 1;
        }
    }

    @autoreleasepool {
        Joycon2BLEReceiver *viewer = [Joycon2BLEReceiver sharedInstance];
#ifndef HID_ENABLE
        Joycon2VirtualHID *hid = [[Joycon2VirtualHID alloc] initWithMode:mode modeOverridden:modeOverridden configPath:configPath];
#endif
        if (viewer
#ifndef HID_ENABLE
            && hid
#endif
            ) {
#ifndef HID_ENABLE
            [hid startEmulation];
#else
            [viewer startScan];
#endif
            CFRunLoopRun();
#ifndef HID_ENABLE
            [hid release];
#endif
        }
    }
    return 0;
}
