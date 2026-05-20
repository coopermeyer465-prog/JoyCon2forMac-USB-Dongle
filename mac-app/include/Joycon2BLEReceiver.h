 #pragma once

 #import <CoreBluetooth/CoreBluetooth.h>
 #import <Foundation/Foundation.h>

#include <vector>
#include <map>
#include <string>
#include <utility>
#include <iomanip>
#include <chrono>
#include <sstream>
#include <iostream>

@interface Joycon2BLEReceiver : NSObject<CBCentralManagerDelegate, CBPeripheralDelegate>

@property (strong, nonatomic) CBCentralManager* centralManager;
@property (strong, nonatomic) CBPeripheral* connectedPeripheral;
@property (strong, nonatomic) CBCharacteristic* writeCharacteristic;
@property (strong, nonatomic) CBCharacteristic* subscribeCharacteristic;
@property (assign, nonatomic) BOOL shouldScan;
@property (strong, nonatomic) NSMutableSet* connectingPeripherals; // Track peripherals we are connecting to
@property (strong, nonatomic) NSMutableSet* connectedPeripherals; // Track peripherals that are connected
@property (strong, nonatomic) NSMutableDictionary* writeCharacteristicsByPeripheral;
@property (strong, nonatomic) NSMutableDictionary* subscribeCharacteristicsByPeripheral;
@property (strong, nonatomic) NSMutableDictionary* deviceTypesByPeripheral;
@property (strong, nonatomic) NSString* deviceType; // Connected device type (L/R/Pro/Unknown)
@property (strong, nonatomic) NSTimer* dataTimeoutTimer; // Data receive timeout timer
@property (strong, nonatomic) NSTimer* commandTimer; // Periodic command sender timer
@property (assign, nonatomic) int displayInterval; // Packet print interval
@property (assign, nonatomic) BOOL skipInitCommands; // Skip sending init commands

// Constants
extern const uint16_t JOYCON2_MANUFACTURER_ID;
extern NSString* const WRITE_CHARACTERISTIC_UUID;
extern NSString* const SUBSCRIBE_CHARACTERISTIC_UUID;

// Global data counter
extern int dataReceiveCounter;

// Logging functions
std::string getTimestamp();
void log(const std::string& level, const std::string& message);

// Initialization
- (instancetype)init;

// Public methods
- (void)startScan;
- (void)stopScan;
- (void)connectToDevice:(NSString*)address;
- (void)disconnect;

 // Callbacks (blocks)
 @property (copy, nonatomic) void (^onDeviceFound)(NSString* name, NSString* address);
 @property (copy, nonatomic) void (^onConnected)(void);
 @property (copy, nonatomic) void (^onDataReceived)(NSDictionary* data);
 @property (copy, nonatomic) void (^onError)(NSString* error);

  // Utility methods
   + (Joycon2BLEReceiver*)sharedInstance;
   + (NSString*)determineDeviceType:(CBPeripheral*)peripheral;
   + (int16_t)toInt16:(const std::vector<uint8_t>&)data offset:(size_t)offset;
  + (uint16_t)toUint16:(const std::vector<uint8_t>&)data offset:(size_t)offset;
  + (uint32_t)toUint24:(const std::vector<uint8_t>&)data offset:(size_t)offset;
  + (uint32_t)toUint32:(const std::vector<uint8_t>&)data offset:(size_t)offset;
   + (std::pair<uint16_t, uint16_t>)parseStick:(const std::vector<uint8_t>&)data offset:(size_t)offset;
  + (std::map<std::string, double>)parseJoycon2Data:(const std::vector<uint8_t>&)data;
  + (std::vector<std::string>)parseButtons:(uint32_t)buttons;
  + (void)printParsedData:(const std::map<std::string, double>&)parsed data:(const std::vector<uint8_t>&)data;
   - (void)sendInitializationCommandsToPeripheral:(CBPeripheral*)peripheral;



 @end
