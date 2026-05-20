#import "../include/Joycon2BLEReceiver.h"
#import <CoreBluetooth/CoreBluetooth.h>
#import <Foundation/Foundation.h>
#include <vector>
#include <map>
#include <string>
#include <iostream>
#include <iomanip>
#include <chrono>
#include <sstream>

// Constants
const uint16_t JOYCON2_MANUFACTURER_ID = 0x0553; // Joy-Con manufacturer ID
NSString* const WRITE_CHARACTERISTIC_UUID = @"649D4AC9-8EB7-4E6C-AF44-1EA54FE5F005";
NSString* const SUBSCRIBE_CHARACTERISTIC_UUID = @"AB7DE9BE-89FE-49AD-828F-118F09DF7FD2";

// Global data counter
int dataReceiveCounter = 0;

// Record connection start time (milliseconds resolution)
std::chrono::time_point<std::chrono::system_clock> connectionStartTime;

static NSString* PeripheralKey(CBPeripheral* peripheral) {
    if (!peripheral) {
        return @"";
    }
    if (peripheral.identifier.UUIDString) {
        return peripheral.identifier.UUIDString;
    }
    return peripheral.name ?: @"";
}

@implementation Joycon2BLEReceiver

- (instancetype)init {
    self = [super init];
    if (self) {
        self.centralManager = [[CBCentralManager alloc] initWithDelegate:self queue:nil];
        self.connectingPeripherals = [[NSMutableSet alloc] init];
        self.connectedPeripherals = [[NSMutableSet alloc] init];
        self.writeCharacteristicsByPeripheral = [[NSMutableDictionary alloc] init];
        self.subscribeCharacteristicsByPeripheral = [[NSMutableDictionary alloc] init];
        self.deviceTypesByPeripheral = [[NSMutableDictionary alloc] init];
        self.deviceType = @"Unknown"; // Default

        // Data receive timeout timer
        self.dataTimeoutTimer = nil;

        // Periodic command sender timer
        self.commandTimer = nil;

        // Set singleton instance (legacy path)
        if (!sharedInstance) {
            sharedInstance = self;
        }
    }
    return self;
}

- (void)startScan {
    self.shouldScan = YES;
    if (self.centralManager.state == CBManagerStatePoweredOn) {
        [self.centralManager scanForPeripheralsWithServices:nil options:nil];
        log("SECTION", "------ Scanning BLE devices ------");
    } else {
        log("INFO", "Waiting for Bluetooth to be ready...");
    }
}

- (void)stopScan {
    [self.centralManager stopScan];
    std::cout << "Scan stopped." << std::endl;
}

- (void)connectToDevice:(NSString*)address {
    // Find peripheral by address and connect
    NSArray* peripherals = [self.centralManager retrieveConnectedPeripheralsWithServices:@[]];
    for (CBPeripheral* peripheral in peripherals) {
        if ([peripheral.identifier.UUIDString isEqualToString:address]) {
            self.connectedPeripheral = peripheral;
            self.connectedPeripheral.delegate = self;
            [self.centralManager connectPeripheral:self.connectedPeripheral options:nil];
            return;
        }
    }
    // If not connected, scan and connect
    [self startScan];
}

- (void)disconnect {
    if (self.connectedPeripheral) {
        [self.centralManager cancelPeripheralConnection:self.connectedPeripheral];
    }
}

// CBCentralManagerDelegate methods
- (void)centralManagerDidUpdateState:(CBCentralManager*)central {
    switch (central.state) {
        case CBManagerStatePoweredOn:
        std::cout << "Bluetooth is powered on." << std::endl;
        //Auto-start scanning if we were waiting for Bluetooth
        if (self.shouldScan) {
            [self startScan];
        }
        break;
        case CBManagerStatePoweredOff:
        std::cout << "Bluetooth is powered off." << std::endl;
        break;
        default:
        std::cout << "Bluetooth state changed." << std::endl;
        break;
    }
}

- (void)centralManager:(CBCentralManager*)central didDiscoverPeripheral:(CBPeripheral*)peripheral advertisementData:(NSDictionary*)advertisementData RSSI:(NSNumber*)RSSI {
    const char* deviceName = peripheral.name ? [peripheral.name UTF8String] : "Unknown";
    const char* deviceUUID = peripheral.identifier ? [peripheral.identifier.UUIDString UTF8String] : "Unknown";

    id manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey];
    if (manufacturerData) {
        uint16_t companyId = 0;
        bool hasValidManufacturerId = false;

        if ([manufacturerData isKindOfClass:[NSDictionary class]]) {
            // manufacturerData may be provided as an NSDictionary
            NSNumber* companyIdNumber = [[manufacturerData allKeys] firstObject];
            if (companyIdNumber) {
                companyId = [companyIdNumber unsignedShortValue];
                companyId = CFSwapInt16LittleToHost(companyId);
                hasValidManufacturerId = true;
            }
        } else if ([manufacturerData isKindOfClass:[NSData class]]) {
            // or as NSData
            NSData* data = (NSData*)manufacturerData;
            if (data.length >= 2) {
                [data getBytes:&companyId length:sizeof(uint16_t)];
                companyId = CFSwapInt16LittleToHost(companyId);
                hasValidManufacturerId = true;
            }
        }

        if (hasValidManufacturerId && companyId == JOYCON2_MANUFACTURER_ID) {
            log("INFO", "Joy-Con found: " + std::string(deviceName) + " (" + std::string(deviceUUID) + ") RSSI: " + std::to_string([RSSI intValue]));
            if (self.onDeviceFound) {
                self.onDeviceFound(peripheral.name, peripheral.identifier.UUIDString);
            }

            // Only connect if we're not already connecting/connected.
            if (![self.connectingPeripherals containsObject:peripheral.identifier] && ![self.connectedPeripherals containsObject:peripheral.identifier]) {
                std::cout << "🔗 Attempting to connect to Joy-Con..." << std::endl;
                [self.connectingPeripherals addObject:peripheral.identifier];
                std::cout << "📊 Connection state updated - Connecting: " << [self.connectingPeripherals count]
                << ", Connected: " << [self.connectedPeripherals count] << std::endl;

                // Connection options (prefer staying connected).
                NSDictionary* connectOptions = @{
                    CBConnectPeripheralOptionNotifyOnConnectionKey: @YES,
                    CBConnectPeripheralOptionNotifyOnDisconnectionKey: @YES,
                    CBConnectPeripheralOptionNotifyOnNotificationKey: @YES,
                    CBConnectPeripheralOptionStartDelayKey: @0  // Connect immediately
                };
                [self.centralManager connectPeripheral:peripheral options:connectOptions];

                // Connection timeout (60s)
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    if ([self.connectingPeripherals containsObject:peripheral.identifier] && ![self.connectedPeripherals containsObject:peripheral.identifier]) {
                        std::cout << "⏰ Connection timeout for " << deviceName << std::endl;
                        [self.connectingPeripherals removeObject:peripheral.identifier];
                        std::cout << "📊 Connection state updated - Connecting: " << [self.connectingPeripherals count]
                        << ", Connected: " << [self.connectedPeripherals count] << std::endl;
                        [self.centralManager cancelPeripheralConnection:peripheral];
                    }
                });
            } else {
                std::cout << "ℹ️  Already connecting/connected to this Joy-Con" << std::endl;
            }
        }
    }
}

- (void)centralManager:(CBCentralManager*)central didConnectPeripheral:(CBPeripheral*)peripheral {
    log("SECTION", "------ Connection Established ------");
    std::string nameStr = peripheral.name ? [peripheral.name UTF8String] : "Unknown";
    log("SUCCESS", "Connected to: " + nameStr);
    log("INFO", "Discovering services and characteristics...");

    // Update connection state.
    [self.connectingPeripherals removeObject:peripheral.identifier];
    [self.connectedPeripherals addObject:peripheral.identifier];

    std::cout << "📊 Connection state updated - Connecting: " << [self.connectingPeripherals count]
    << ", Connected: " << [self.connectedPeripherals count] << std::endl;

    self.connectedPeripheral = peripheral;
    self.connectedPeripheral.delegate = self;

    // Determine and store device type.
    self.deviceType = [Joycon2BLEReceiver determineDeviceType:peripheral];
    NSString* peripheralKey = PeripheralKey(peripheral);
    if (peripheralKey.length > 0) {
        [self.deviceTypesByPeripheral setObject:self.deviceType forKey:peripheralKey];
    }
    std::cout << "🎮 Device type detected: " << [self.deviceType UTF8String] << std::endl;

    // Start data timeout timer (30s).
    [self startDataTimeoutTimer];

    // Record connection start time.
    connectionStartTime = std::chrono::system_clock::now();

    std::cout << "ℹ️  Initialization will begin after discovery" << std::endl;

    [peripheral discoverServices:nil];
    
    if (self.onConnected) {
        self.onConnected();
    }
}

- (void)centralManager:(CBCentralManager*)central didFailToConnectPeripheral:(CBPeripheral*)peripheral error:(NSError*)error {
    std::cout << "❌ Failed to connect to " << [peripheral.name UTF8String] << ": " << [error.localizedDescription UTF8String] << std::endl;
    std::cout << "❌ Error code: " << [error code] << std::endl;
    std::cout << "❌ Error domain: " << [error.domain UTF8String] << std::endl;

    // Clean up connection state.
    [self.connectingPeripherals removeObject:peripheral.identifier];
    std::cout << "📊 Connection state updated - Connecting: " << [self.connectingPeripherals count]
              << ", Connected: " << [self.connectedPeripherals count] << std::endl;

    // Retry connection.
    std::cout << "🔄 Retrying connection in 2 seconds..." << std::endl;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        std::cout << "🔄 Retrying connection..." << std::endl;
        [self startScan];
    });

    if (self.onError) {
        self.onError(error.localizedDescription);
    }
}

- (void)centralManager:(CBCentralManager*)central didDisconnectPeripheral:(CBPeripheral*)peripheral error:(NSError*)error {
    if (error) {
        std::cout << "🔌 Disconnected from " << [peripheral.name UTF8String] << " with error: " << [error.localizedDescription UTF8String] << std::endl;
        std::cout << "❌ Error code: " << [error code] << std::endl;
    } else {
        std::cout << "🔌 Disconnected from " << [peripheral.name UTF8String] << " (no error)" << std::endl;
    }

    // Stop timers.
    [self invalidateDataTimeoutTimer];

    [self invalidateCommandTimer];

    // Clean up connection state.
    [self.connectedPeripherals removeObject:peripheral.identifier];
    [self.connectingPeripherals removeObject:peripheral.identifier];
    NSString* peripheralKey = PeripheralKey(peripheral);
    if (peripheralKey.length > 0) {
        [self.writeCharacteristicsByPeripheral removeObjectForKey:peripheralKey];
        [self.subscribeCharacteristicsByPeripheral removeObjectForKey:peripheralKey];
        [self.deviceTypesByPeripheral removeObjectForKey:peripheralKey];
    }
    std::cout << "📊 Connection state updated - Connecting: " << [self.connectingPeripherals count]
              << ", Connected: " << [self.connectedPeripherals count] << std::endl;

    // Attempt reconnect.
    std::cout << "🔄 Attempting to reconnect in 3 seconds..." << std::endl;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        std::cout << "🔄 Reconnecting..." << std::endl;
        [self startScan];
    });
}

// CBPeripheralDelegate methods
- (void)peripheral:(CBPeripheral*)peripheral didDiscoverServices:(NSError*)error {
    if (error) {
        std::cout << "Error discovering services: " << [error.localizedDescription UTF8String] << std::endl;
        return;
    }

    std::cout << "Discovered " << [peripheral.services count] << " services" << std::endl;
    for (CBService* service in peripheral.services) {
        std::cout << "Service: " << [service.UUID.UUIDString UTF8String] << std::endl;
        [peripheral discoverCharacteristics:nil forService:service];
    }
}

- (void)peripheral:(CBPeripheral*)peripheral didDiscoverCharacteristicsForService:(CBService*)service error:(NSError*)error {
    if (error) {
        log("ERROR", "Error discovering characteristics: " + std::string([error.localizedDescription UTF8String]));
        return;
    }

    log("SECTION", "------ Service Discovery ------");
    log("INFO", "Discovered " + std::to_string([service.characteristics count]) + " characteristics for service " + std::string([service.UUID.UUIDString UTF8String]));
    NSString* peripheralKey = PeripheralKey(peripheral);
    CBCharacteristic* writeCharacteristic = peripheralKey.length > 0 ? [self.writeCharacteristicsByPeripheral objectForKey:peripheralKey] : nil;
    CBCharacteristic* subscribeCharacteristic = peripheralKey.length > 0 ? [self.subscribeCharacteristicsByPeripheral objectForKey:peripheralKey] : nil;

    for (CBCharacteristic* characteristic in service.characteristics) {
        std::cout << "  Characteristic: " << [characteristic.UUID.UUIDString UTF8String] << " (Properties: " << characteristic.properties << ")" << std::endl;
        if ([characteristic.UUID.UUIDString isEqualToString:WRITE_CHARACTERISTIC_UUID]) {
            std::cout << "    ✓ Found WRITE characteristic" << std::endl;
            writeCharacteristic = characteristic;
            if (peripheralKey.length > 0) {
                [self.writeCharacteristicsByPeripheral setObject:characteristic forKey:peripheralKey];
            }
        } else if ([characteristic.UUID.UUIDString isEqualToString:SUBSCRIBE_CHARACTERISTIC_UUID]) {
            std::cout << "    ✓ Found SUBSCRIBE characteristic" << std::endl;
            subscribeCharacteristic = characteristic;
            if (peripheralKey.length > 0) {
                [self.subscribeCharacteristicsByPeripheral setObject:characteristic forKey:peripheralKey];
            }
            std::cout << "    📡 Enabling notifications for data stream..." << std::endl;
            [peripheral setNotifyValue:YES forCharacteristic:characteristic];
        } else {
            // Fallback: first writable characteristic.
            if (characteristic.properties & CBCharacteristicPropertyWrite) {
                std::cout << "    💡 Found writable characteristic: " << [characteristic.UUID.UUIDString UTF8String] << std::endl;
                if (!writeCharacteristic) {
                    std::cout << "    🔧 Using this as WRITE characteristic" << std::endl;
                    writeCharacteristic = characteristic;
                    if (peripheralKey.length > 0) {
                        [self.writeCharacteristicsByPeripheral setObject:characteristic forKey:peripheralKey];
                    }
                }
            }
            // Fallback: first notifiable characteristic.
            if (characteristic.properties & CBCharacteristicPropertyNotify) {
                if ([characteristic.UUID.UUIDString isEqualToString:SUBSCRIBE_CHARACTERISTIC_UUID]) {
                    std::cout << "    📡 Found notifiable characteristic: " << [characteristic.UUID.UUIDString UTF8String] << std::endl;
                    std::cout << "    ✓ Found SUBSCRIBE characteristic" << std::endl;
                    subscribeCharacteristic = characteristic;
                    if (peripheralKey.length > 0) {
                        [self.subscribeCharacteristicsByPeripheral setObject:characteristic forKey:peripheralKey];
                    }
                }
            }
        }
    }

    // Check after service discovery completes.
    if (writeCharacteristic && subscribeCharacteristic) {
        self.writeCharacteristic = writeCharacteristic;
        self.subscribeCharacteristic = subscribeCharacteristic;
        std::cout << "✓ All required characteristics found, preparing for notification..." << std::endl;

        // Send init commands after characteristics are found.
        std::cout << "skipInitCommands: " << (self.skipInitCommands ? "YES" : "NO") << std::endl;
        if (!self.skipInitCommands) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                std::cout << "🚀 Sending initialization commands after characteristics discovery..." << std::endl;
                [self sendInitializationCommandsToPeripheral:peripheral];
            });
        }

        // Ensure notifications are enabled after a short delay.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            std::cout << "📡 Enabling notifications for data stream..." << std::endl;
            [peripheral setNotifyValue:YES forCharacteristic:subscribeCharacteristic];
        });
     } else {
        std::cout << "Waiting for all characteristics... (WRITE: " << (writeCharacteristic ? "✓" : "✗") << ", SUBSCRIBE: " << (subscribeCharacteristic ? "✓" : "✗") << ")" << std::endl;
     }
}

- (void)peripheral:(CBPeripheral*)peripheral didUpdateValueForCharacteristic:(CBCharacteristic*)characteristic error:(NSError*)error {
    if (error) {
        std::cout << "Error receiving data from " << [characteristic.UUID.UUIDString UTF8String] << ": " << [error.localizedDescription UTF8String] << std::endl;
        return;
    }

    NSData* data = characteristic.value;

    if ([characteristic.UUID.UUIDString isEqualToString:SUBSCRIBE_CHARACTERISTIC_UUID]) {
        if (data.length > 0) {
            // Size check.
            if (data.length < 0x3C) {
                std::cout << "⚠️  Received data packet too small (" << data.length << " bytes, expected >= 60)" << std::endl;
                return;
            }

            // Detailed receive log.
            dataReceiveCounter++;
            std::string nameStr = peripheral.name ? [peripheral.name UTF8String] : "Unknown";
            log("SECTION", "------ " + nameStr + " Data Packet #" + std::to_string(dataReceiveCounter) + " ------");
            log("INFO", "Received data packet #" + std::to_string(dataReceiveCounter) + " (" + std::to_string(data.length) + " bytes)");



            // Reset timeout timer.
            [self resetDataTimeoutTimer];

            try {
                std::vector<uint8_t> dataVector((uint8_t*)data.bytes, (uint8_t*)data.bytes + data.length);

                // Validate data vector.
                if (dataVector.size() < 0x3C) {
                    std::cout << "❌ Data vector size invalid: " << dataVector.size() << std::endl;
                    return;
                }

                auto parsedData = [Joycon2BLEReceiver parseJoycon2Data:dataVector];

                // Extra log when packetId is around ~70 (debugging).
                int packetId = (int)parsedData.at("PacketID");
                if (packetId >= 65 && packetId <= 75) {
                    std::cout << "🔍 PacketID around 70: " << packetId << std::endl;
                }



                // Print parsed values.
                [Joycon2BLEReceiver printParsedData:parsedData data:dataVector];

                if (self.onDataReceived) {
                    NSMutableDictionary* dict = [NSMutableDictionary dictionary];
                    for (const auto& pair : parsedData) {
                        [dict setObject:@(pair.second) forKey:[NSString stringWithUTF8String:pair.first.c_str()]];
                    }
                    NSString* packetDeviceType = [Joycon2BLEReceiver determineDeviceType:peripheral];
                    NSString* peripheralKey = PeripheralKey(peripheral);
                    dict[@"DeviceType"] = packetDeviceType ?: @"Unknown";
                    dict[@"PeripheralIdentifier"] = peripheralKey ?: @"";
                    dict[@"PeripheralName"] = peripheral.name ?: @"Unknown Device";
                    self.onDataReceived(dict);
                }
            } catch (const std::exception& e) {
                std::cout << "❌ Data parsing error: " << e.what() << std::endl;
            } catch (...) {
                std::cout << "❌ Unknown data parsing error" << std::endl;
            }
        } else {
            std::cout << "⚠️  Received empty data packet" << std::endl;
        }
    } else {
        // Ignore other characteristics by default (enable for debugging if needed).
        // if (data.length > 0) {
        //     std::cout << "📄 Received " << data.length << " bytes from " << [characteristic.UUID.UUIDString UTF8String] << std::endl;
        // }
    }
}

- (void)peripheral:(CBPeripheral*)peripheral didUpdateNotificationStateForCharacteristic:(CBCharacteristic*)characteristic error:(NSError*)error {
    if (error) {
        std::cout << "❌ Failed to enable notifications for " << [characteristic.UUID.UUIDString UTF8String] << ": " << [error.localizedDescription UTF8String] << std::endl;
        std::cout << "❌ Error code: " << [error code] << std::endl;
        std::cout << "❌ Error domain: " << [error.domain UTF8String] << std::endl;
    } else {
        if ([characteristic.UUID.UUIDString isEqualToString:SUBSCRIBE_CHARACTERISTIC_UUID]) {
            std::cout << "✅ Notifications enabled for characteristic: " << [characteristic.UUID.UUIDString UTF8String] << std::endl;
            std::cout << "🎯 Ready to receive Joy-Con data! Move the controller to see sensor data..." << std::endl;
        }
    }
}

- (void)peripheral:(CBPeripheral*)peripheral didWriteValueForCharacteristic:(CBCharacteristic*)characteristic error:(NSError*)error {
    if (error) {
        std::cout << "❌ Failed to write value to characteristic: " << [error.localizedDescription UTF8String] << std::endl;
    } else {
        std::cout << "✅ Successfully wrote value to characteristic: " << [characteristic.UUID.UUIDString UTF8String] << std::endl;
    }
}



- (void)sendInitializationCommandsOnce {
    [self sendInitializationCommandsToPeripheral:self.connectedPeripheral];
}

- (void)sendInitializationCommandsToPeripheral:(CBPeripheral*)peripheral {
    if (!peripheral) {
        std::cout << "❌ Cannot send initialization commands without a connected peripheral" << std::endl;
        return;
    }

    NSString* peripheralKey = PeripheralKey(peripheral);
    CBCharacteristic* writeCharacteristic = peripheralKey.length > 0 ? [self.writeCharacteristicsByPeripheral objectForKey:peripheralKey] : self.writeCharacteristic;
    if (!writeCharacteristic) {
        std::cout << "❌ Missing WRITE characteristic for " << [peripheral.name UTF8String] << std::endl;
        return;
    }

    std::cout << "🚀 sendInitializationCommandsOnce called" << std::endl;
    auto currentTime = std::chrono::system_clock::now();
    auto currentMs = std::chrono::duration_cast<std::chrono::milliseconds>(currentTime.time_since_epoch()).count();
    std::cout << "⏱️  Init commands sent at: " << currentMs << " ms" << std::endl;
    // Joy-Con 2 initialization commands
    NSArray* commands = @[
        // Command 1: enable button notifications
        [NSData dataWithBytes:(uint8_t[]){0x0c, 0x91, 0x01, 0x02, 0x00, 0x04, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00} length:12],
        // Command 2: enable IMU / mouse notifications
        [NSData dataWithBytes:(uint8_t[]){0x0c, 0x91, 0x01, 0x04, 0x00, 0x04, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00} length:12]
    ];
    for (int i = 0; i < commands.count; i++) {
        std::cout << "📤 Sending command " << (i + 1) << "/" << commands.count << " (length: " << [commands[i] length] << ")" << std::endl;

        // Print command bytes (hex)
        const uint8_t* bytes = (const uint8_t*)[commands[i] bytes];
        std::cout << "   Command hex: ";
        for (NSUInteger j = 0; j < [commands[i] length]; j++) {
            std::cout << std::hex << std::uppercase << std::setfill('0') << std::setw(2) << (int)bytes[j];
            if (j < [commands[i] length] - 1) std::cout << " ";
        }
        std::cout << std::dec << std::endl;

        CBCharacteristicWriteType writeType = CBCharacteristicWriteWithoutResponse;
        [peripheral writeValue:commands[i] forCharacteristic:writeCharacteristic type:writeType];

        std::cout << "✅ Command " << (i + 1) << " sent" << std::endl;

        // Wait 500ms between commands
        if (i < commands.count - 1) {
            [NSThread sleepForTimeInterval:0.5];
        }
    }
}

- (void)sendWriteCommands {
    std::cout << "🚀 Sending initialization commands to Joy-Con..." << std::endl;

    // Joy-Con 2 initialization commands
    NSArray* commands = @[
        // Command 1
        [NSData dataWithBytes:(uint8_t[]){0x0c, 0x91, 0x01, 0x02, 0x00, 0x04, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00} length:12],
        // Command 2
        [NSData dataWithBytes:(uint8_t[]){0x0c, 0x91, 0x01, 0x04, 0x00, 0x04, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00} length:12]
    ];

    // Send both commands
    for (int i = 0; i < commands.count; i++) {
        std::cout << "📤 Sending command " << (i + 1) << "/" << commands.count << " (length: " << [commands[i] length] << ")" << std::endl;

        CBCharacteristicWriteType writeType = CBCharacteristicWriteWithoutResponse;
        [self.connectedPeripheral writeValue:commands[i] forCharacteristic:self.writeCharacteristic type:writeType];

        std::cout << "✅ Command " << (i + 1) << " sent" << std::endl;
    }

    std::cout << "🎯 All initialization commands sent successfully! Waiting for Joy-Con data..." << std::endl;
}



// Singleton instance
static Joycon2BLEReceiver* sharedInstance = nil;

+ (Joycon2BLEReceiver*)sharedInstance {
    if (!sharedInstance) {
        sharedInstance = [[Joycon2BLEReceiver alloc] init];
    }
    return sharedInstance;
}

+ (NSString*)determineDeviceType:(CBPeripheral*)peripheral {
    if (!peripheral) {
        return @"Unknown";
    }

    // Determine from device name (best-effort)
    NSString* deviceName = peripheral.name;
    if (deviceName) {
        if ([deviceName containsString:@"(L)"] || [deviceName containsString:@"Left"] || [deviceName containsString:@"Joy-Con2 (L)"]) {
            return @"L";
        } else if ([deviceName containsString:@"(R)"] || [deviceName containsString:@"Right"] || [deviceName containsString:@"Joy-Con2 (R)"]) {
            return @"R";
        } else if ([deviceName containsString:@"Pro Controller2"]) {
            return @"Pro";
        }
    }

    // Default
    return @"Unknown";
}

// C++ utility functions
+ (int16_t)toInt16:(const std::vector<uint8_t>&)data offset:(size_t)offset {
    // Bounds check
    if (offset + 2 > data.size()) {
        std::cout << "❌ Buffer overflow in toInt16: offset=" << offset << ", size=" << data.size() << std::endl;
        return 0;
    }
    int16_t value;
    memcpy(&value, &data[offset], sizeof(int16_t));
    return CFSwapInt16LittleToHost(value);
}

+ (uint16_t)toUint16:(const std::vector<uint8_t>&)data offset:(size_t)offset {
    // Bounds check
    if (offset + 2 > data.size()) {
        std::cout << "❌ Buffer overflow in toUint16: offset=" << offset << ", size=" << data.size() << std::endl;
        return 0;
    }
    uint16_t value;
    memcpy(&value, &data[offset], sizeof(uint16_t));
    return CFSwapInt16LittleToHost(value);
}

+ (uint32_t)toUint24:(const std::vector<uint8_t>&)data offset:(size_t)offset {
    // Bounds check
    if (offset + 3 > data.size()) {
        std::cout << "❌ Buffer overflow in toUint24: offset=" << offset << ", size=" << data.size() << std::endl;
        return 0;
    }
    uint32_t value = 0;
    memcpy(&value, &data[offset], 3);
    return CFSwapInt32LittleToHost(value) & 0xFFFFFF;
}

+ (uint32_t)toUint32:(const std::vector<uint8_t>&)data offset:(size_t)offset {
    // Bounds check
    if (offset + 4 > data.size()) {
        std::cout << "❌ Buffer overflow in toUint32: offset=" << offset << ", size=" << data.size() << std::endl;
        return 0;
    }
    uint32_t value;
    memcpy(&value, &data[offset], sizeof(uint32_t));
    return CFSwapInt32LittleToHost(value);
}

+ (std::pair<uint16_t, uint16_t>)parseStick:(const std::vector<uint8_t>&)data offset:(size_t)offset {
    std::vector<uint8_t> d(data.begin() + offset, data.begin() + offset + 3);
    uint32_t val = 0;
    memcpy(&val, d.data(), 3);
    uint16_t x = val & 0xFFF;
    uint16_t y = (val >> 12) & 0xFFF;
    return {x, y};
}

+ (std::map<std::string, double>)parseJoycon2Data:(const std::vector<uint8_t>&)data {
    std::map<std::string, double> parsed;

    // Size check.
    if (data.size() < 0x3C) {
        std::cout << "❌ Insufficient data size for parsing: " << data.size() << " bytes" << std::endl;
        return parsed; // Return empty map
    }

    parsed["PacketID"] = (double) [Joycon2BLEReceiver toUint24:data offset:0];
    parsed["Buttons"] = (double) [Joycon2BLEReceiver toUint32:data offset:3];

    parsed["TriggerL"] = (double) data[0x3C];
    parsed["TriggerR"] = (double) data[0x3D];

    auto leftStick = [Joycon2BLEReceiver parseStick:data offset:0x0A];
    parsed["LeftStickX"] = (double) leftStick.first;
    parsed["LeftStickY"] = (double) leftStick.second;
    auto rightStick = [Joycon2BLEReceiver parseStick:data offset:0x0D];
    parsed["RightStickX"] = (double) rightStick.first;
    parsed["RightStickY"] = (double) rightStick.second;

    parsed["AccelX"] = (double) [Joycon2BLEReceiver toInt16:data offset:0x30];
    parsed["AccelY"] = (double) [Joycon2BLEReceiver toInt16:data offset:0x32];
    parsed["AccelZ"] = (double) [Joycon2BLEReceiver toInt16:data offset:0x34];

    parsed["GyroX"] = (double) [Joycon2BLEReceiver toInt16:data offset:0x36];
    parsed["GyroY"] = (double) [Joycon2BLEReceiver toInt16:data offset:0x38];
    parsed["GyroZ"] = (double) [Joycon2BLEReceiver toInt16:data offset:0x3A];

    parsed["MagX"] = (double) [Joycon2BLEReceiver toInt16:data offset:0x18];
    parsed["MagY"] = (double) [Joycon2BLEReceiver toInt16:data offset:0x1A];
    parsed["MagZ"] = (double) [Joycon2BLEReceiver toInt16:data offset:0x1C];

    parsed["MouseX"] = (double) [Joycon2BLEReceiver toInt16:data offset:0x10];
    parsed["MouseY"] = (double) [Joycon2BLEReceiver toInt16:data offset:0x12];
    parsed["MouseUnk"] = (double) [Joycon2BLEReceiver toInt16:data offset:0x14];
    parsed["MouseDistance"] = (double) [Joycon2BLEReceiver toInt16:data offset:0x16];

    parsed["BatteryVoltageRaw"] = (double) [Joycon2BLEReceiver toUint16:data offset:0x1F];
    parsed["BatteryCurrentRaw"] = (double) [Joycon2BLEReceiver toInt16:data offset:0x28];

    parsed["TemperatureRaw"] = (double) [Joycon2BLEReceiver toInt16:data offset:0x2E];

    // Derived values.
    parsed["BatteryVoltage"] = parsed["BatteryVoltageRaw"] / 1000.0;
    parsed["BatteryCurrent"] = parsed["BatteryCurrentRaw"] / 100.0;
    parsed["Temperature"] = 25.0 + parsed["TemperatureRaw"] / 127.0;

    return parsed;
}

+ (std::vector<std::string>)parseButtons:(uint32_t)buttons {
    std::vector<std::string> buttonNames;
    std::map<uint32_t, std::string> buttonMasks = {
        {0x80000000, "ZL"}, {0x40000000, "L"}, {0x00010000, "SELECT"},
        {0x00080000, "LS"}, {0x01000000, "↓"}, {0x02000000, "↑"},
        {0x04000000, "→"}, {0x08000000, "←"}, {0x00200000, "CAMERA"},
        {0x10000000, "SR(L)"}, {0x20000000, "SL(L)"}, {0x00100000, "HOME"},
        {0x00400000, "CHAT"}, {0x00020000, "START"}, {0x00001000, "SR(R)"},
        {0x00002000, "SL(R)"}, {0x00004000, "R"}, {0x00008000, "ZR"},
        {0x00040000, "RS"}, {0x00000100, "Y"}, {0x00000200, "X"},
        {0x00000400, "B"}, {0x00000800, "A"}
    };

    for (const auto& mask : buttonMasks) {
        if (buttons & mask.first) {
            buttonNames.push_back(mask.second);
        }
    }

    return buttonNames;
}

// Track last mouse position and a print counter.
static int16_t lastMouseX = 0;
static int16_t lastMouseY = 0;
static int dataCounter = 0;

+ (void)printParsedData:(const std::map<std::string, double>&)parsed data:(const std::vector<uint8_t>&)data {
    dataCounter++;
    auto currentTime = std::chrono::system_clock::now();
    auto currentMs = std::chrono::duration_cast<std::chrono::milliseconds>(currentTime.time_since_epoch()).count();

    // Print interval check.
    Joycon2BLEReceiver* client = [Joycon2BLEReceiver sharedInstance];
    if (client.displayInterval > 1 && (dataCounter % client.displayInterval) != 0) {
        return; // Skip
    }

    #ifdef DEBUG
        // Debug mode: normal log output.
        auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(currentTime - connectionStartTime).count();
        log("DATA", "Elapsed: " + std::to_string(elapsed) + " ms");

        std::stringstream hexStream;
        hexStream << std::hex << std::uppercase << std::setfill('0') << std::setw(2);
        for (size_t i = 0; i < data.size(); ++i) {
            hexStream << (int)(uint8_t)data[i];
            if (i < data.size() - 1) hexStream << " ";
        }
        log("DATA", "Packet_HEX: " + hexStream.str());

        log("DATA", "PacketID: " + std::to_string((int)parsed.at("PacketID")));

        uint32_t buttons = (uint32_t)parsed.at("Buttons");
        std::stringstream buttonHex;
        buttonHex << std::hex << std::uppercase << std::setfill('0') << std::setw(8) << buttons;
        log("DATA", "Buttons: 0x" + buttonHex.str());

        auto buttonNames = [Joycon2BLEReceiver parseButtons:buttons];
        std::string pressed = buttonNames.empty() ? "None" : "";
        for (size_t i = 0; i < buttonNames.size(); ++i) {
            pressed += buttonNames[i];
            if (i < buttonNames.size() - 1) pressed += ", ";
        }
        log("DATA", "Pressed: " + pressed);

        log("DATA", "Analog_Triggers: L=" + std::to_string((int)parsed.at("TriggerL")) + ", R=" + std::to_string((int)parsed.at("TriggerR")));

        log("DATA", "LeftStick: X=" + std::to_string((int)parsed.at("LeftStickX")) + ", Y=" + std::to_string((int)parsed.at("LeftStickY")));
        log("DATA", "RightStick: X=" + std::to_string((int)parsed.at("RightStickX")) + ", Y=" + std::to_string((int)parsed.at("RightStickY")));

        log("DATA", "Accel: X=" + std::to_string((int)parsed.at("AccelX")) + ", Y=" + std::to_string((int)parsed.at("AccelY")) + ", Z=" + std::to_string((int)parsed.at("AccelZ")));
        log("DATA", "Gyro: X=" + std::to_string((int)parsed.at("GyroX")) + ", Y=" + std::to_string((int)parsed.at("GyroY")) + ", Z=" + std::to_string((int)parsed.at("GyroZ")));
        log("DATA", "Mag: X=" + std::to_string((int)parsed.at("MagX")) + ", Y=" + std::to_string((int)parsed.at("MagY")) + ", Z=" + std::to_string((int)parsed.at("MagZ")));

        int16_t currentMouseX = (int16_t)parsed.at("MouseX");
        int16_t currentMouseY = (int16_t)parsed.at("MouseY");
        int16_t deltaX = currentMouseX - lastMouseX;
        int16_t deltaY = currentMouseY - lastMouseY;
        log("DATA", "Mouse: X=" + std::to_string(currentMouseX) + ", Y=" + std::to_string(currentMouseY) + ", DeltaX=" + std::to_string(deltaX) + ", DeltaY=" + std::to_string(deltaY));

        lastMouseX = currentMouseX;
        lastMouseY = currentMouseY;

        std::stringstream battery;
        battery << std::fixed << std::setprecision(2) << parsed.at("BatteryVoltage") << "V, " << parsed.at("BatteryCurrent") << "mA";
        log("DATA", "Battery: " + battery.str());

        std::stringstream temp;
        temp << std::fixed << std::setprecision(1) << parsed.at("Temperature") << "°C";
        log("DATA", "Temperature: " + temp.str());

        std::cout << std::flush;
    #else
        // Release mode: clear screen and print.
        std::cout << "\033[2J\033[1;1H"; // Clear screen + move cursor

        std::cout << "=================================================" << std::endl;
        // Print device name.
        Joycon2BLEReceiver* viewer = [Joycon2BLEReceiver sharedInstance];
        NSString* deviceName = viewer.connectedPeripheral.name;
        std::string nameStr = deviceName ? [deviceName UTF8String] : "Unknown Device";
        std::cout << nameStr << " Data:" << std::endl;
        std::cout << "=================================================" << std::endl;

        auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(currentTime - connectionStartTime).count();
        std::cout << "Elapsed: " << elapsed << " ms" << std::endl;

        std::stringstream hexStream;
        hexStream << std::hex << std::uppercase << std::setfill('0') << std::setw(2);
        for (size_t i = 0; i < data.size(); ++i) {
            hexStream << (int)(uint8_t)data[i];
            if (i < data.size() - 1) hexStream << " ";
        }
        std::cout << "Packet_HEX: " << hexStream.str() << std::endl;

        std::cout << "PacketID: " << (int)parsed.at("PacketID") << std::endl;

        uint32_t buttons = (uint32_t)parsed.at("Buttons");
        std::stringstream buttonHex;
        buttonHex << std::hex << std::uppercase << std::setfill('0') << std::setw(8) << buttons;
        std::cout << "Buttons: " << buttonHex.str() << std::endl;

        auto buttonNames = [Joycon2BLEReceiver parseButtons:buttons];
        std::string pressed = buttonNames.empty() ? "None" : "";
        for (size_t i = 0; i < buttonNames.size(); ++i) {
            pressed += buttonNames[i];
            if (i < buttonNames.size() - 1) pressed += ", ";
        }
        std::cout << "Pressed: " << pressed << std::endl;

        std::cout << "Analog_Triggers: L=" << (int)parsed.at("TriggerL") << ", R=" << (int)parsed.at("TriggerR") << std::endl;

        std::cout << "LeftStick: X=" << (int)parsed.at("LeftStickX") << ", Y=" << (int)parsed.at("LeftStickY") << std::endl;
        std::cout << "RightStick: X=" << (int)parsed.at("RightStickX") << ", Y=" << (int)parsed.at("RightStickY") << std::endl;

        std::cout << "Accel: X=" << (int)parsed.at("AccelX") << ", Y=" << (int)parsed.at("AccelY") << ", Z=" << (int)parsed.at("AccelZ") << std::endl;
        std::cout << "Gyro: X=" << (int)parsed.at("GyroX") << ", Y=" << (int)parsed.at("GyroY") << ", Z=" << (int)parsed.at("GyroZ") << std::endl;
        std::cout << "Mag: X=" << (int)parsed.at("MagX") << ", Y=" << (int)parsed.at("MagY") << ", Z=" << (int)parsed.at("MagZ") << std::endl;

        int16_t currentMouseX = (int16_t)parsed.at("MouseX");
        int16_t currentMouseY = (int16_t)parsed.at("MouseY");
        int16_t deltaX = currentMouseX - lastMouseX;
        int16_t deltaY = currentMouseY - lastMouseY;
        std::cout << "Mouse: X=" << currentMouseX << ", Y=" << currentMouseY << ", DeltaX=" << deltaX << ", DeltaY=" << deltaY << std::endl;

        lastMouseX = currentMouseX;
        lastMouseY = currentMouseY;

        std::stringstream battery;
        battery << std::fixed << std::setprecision(2) << parsed.at("BatteryVoltage") << "V, " << parsed.at("BatteryCurrent") << "mA";
        std::cout << "Battery: " << battery.str() << std::endl;

        std::stringstream temp;
        temp << std::fixed << std::setprecision(1) << parsed.at("Temperature") << "°C";
        std::cout << "Temperature: " << temp.str() << std::endl;

        std::cout << std::flush;
    #endif
}

- (void)startDataTimeoutTimer {
    [self invalidateDataTimeoutTimer]; // Clear any existing timer
    self.dataTimeoutTimer = [NSTimer scheduledTimerWithTimeInterval:30.0
                                                             target:self
                                                           selector:@selector(dataTimeoutFired:)
                                                           userInfo:nil
                                                            repeats:NO];
}

- (void)resetDataTimeoutTimer {
    if (self.dataTimeoutTimer) {
        [self.dataTimeoutTimer invalidate];
        self.dataTimeoutTimer = nil;
    }
    // Start a new timer.
    [self startDataTimeoutTimer];
}

- (void)invalidateDataTimeoutTimer {
    if (self.dataTimeoutTimer) {
        [self.dataTimeoutTimer invalidate];
        self.dataTimeoutTimer = nil;
        std::cout << "⏰ Data timeout timer invalidated" << std::endl;
    }
}

- (void)invalidateCommandTimer {
 if (self.commandTimer) {
        [self.commandTimer invalidate];
        self.commandTimer = nil;
        std::cout << "⏰ Command timer invalidated" << std::endl;
    }
}



- (void)dataTimeoutFired:(NSTimer*)timer {
    auto currentTime = std::chrono::system_clock::now();
    auto currentMs = std::chrono::duration_cast<std::chrono::milliseconds>(currentTime.time_since_epoch()).count();

    std::cout << "⏰ Data timeout fired! No data received for 30 seconds." << std::endl;
    std::cout << "🔍 Checking connection status..." << std::endl;

    // Check connection state.
    if (self.connectedPeripheral) {
        std::cout << "📡 Connected peripheral: " << [self.connectedPeripheral.name UTF8String] << std::endl;
        std::cout << "🔌 Connection state: " << self.connectedPeripheral.state << std::endl;
    } else {
        std::cout << "❌ No connected peripheral" << std::endl;
    }

    // Compute connection duration at packet loss (ms).
    auto connectionDuration = std::chrono::duration_cast<std::chrono::milliseconds>(currentTime - connectionStartTime).count();
    std::cout << "⏱️  Connection duration before packet loss: " << connectionDuration << " ms (" << connectionDuration / 1000 << "s " << connectionDuration % 1000 << "ms)" << std::endl;
    std::cout << "📊 Final data counter: " << dataReceiveCounter << " packets received" << std::endl;

    std::cout << "🛑 Stopping program due to packet loss..." << std::endl;

    // Exit process.
    exit(0);
}

// Logging functions implementation
std::string getTimestamp() {
    auto now = std::chrono::system_clock::now();
    auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(now.time_since_epoch()) % 1000;
    auto time_t_now = std::chrono::system_clock::to_time_t(now);
    std::tm* tm = std::localtime(&time_t_now);
    if (!tm) {
        return "Invalid time";
    }
    std::stringstream ss;
    ss << std::put_time(tm, "%Y-%m-%d %H:%M:%S") << "." << std::setfill('0') << std::setw(3) << ms.count();
    return ss.str();
}

void log(const std::string& level, const std::string& message) {
#ifdef DEBUG
    std::cout << "[" << getTimestamp() << "] [" << level << "] " << message << std::endl;
#endif
}

@end
