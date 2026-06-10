#pragma once
#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

// ---------------------------------------------------------------------------
// DLDevice — represents a single connected DeckLink device
// ---------------------------------------------------------------------------
@interface DLDevice : NSObject
@property (readonly, nonatomic, copy) NSString *name;
/// Stable ID built from the device name (used for persistence).
@property (readonly, nonatomic, copy) NSString *deviceID;
@end

// ---------------------------------------------------------------------------
// DLDeviceEnumerator — lists available DeckLink devices
// ---------------------------------------------------------------------------
@interface DLDeviceEnumerator : NSObject
/// YES if the DeckLink runtime bundle is present on this machine.
+ (BOOL)isAvailable;
/// Returns all currently connected DeckLink devices.
+ (NSArray<DLDevice *> *)availableDevices;
@end

// ---------------------------------------------------------------------------
// DLCaptureSession — captures frames from one DeckLink device
// Callback is called on a private background thread for every frame.
// ---------------------------------------------------------------------------
typedef void (^DLFrameCallback)(CVPixelBufferRef pixelBuffer);

@interface DLCaptureSession : NSObject
/// Returns nil if the device cannot provide an input interface.
- (nullable instancetype)initWithDevice:(DLDevice *)device;
- (void)startWithCallback:(DLFrameCallback)callback;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
