#pragma once
#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

// ---------------------------------------------------------------------------
// NDISource — a single NDI source on the network (e.g. "MACHINE (OBS)")
// ---------------------------------------------------------------------------
@interface NDISource : NSObject
/// Full NDI name, "MACHINE (Source)". Enough on its own to connect.
@property (readonly, nonatomic, copy) NSString *name;
/// Stable ID built from the source name (used for persistence).
@property (readonly, nonatomic, copy) NSString *sourceID;
/// Address reported by discovery; nil for a source rebuilt from a saved name.
@property (readonly, nonatomic, copy, nullable) NSString *urlAddress;

- (instancetype)initWithName:(NSString *)name;
@end

// ---------------------------------------------------------------------------
// NDISourceFinder — lists NDI sources visible on the network
// ---------------------------------------------------------------------------
@interface NDISourceFinder : NSObject
/// YES if the NDI runtime (libndi.dylib) is present on this machine.
+ (BOOL)isAvailable;
/// Returns the sources discovered so far. Discovery keeps running in the
/// background after the first call; that first call blocks for up to
/// `timeoutMs` while sources are announced, so call it off the main thread.
+ (NSArray<NDISource *> *)availableSourcesWithTimeout:(uint32_t)timeoutMs;
@end

// ---------------------------------------------------------------------------
// NDICaptureSession — receives video frames from one NDI source
// Callback is called on a private background thread for every frame, with a
// kCVPixelFormatType_32BGRA buffer.
// ---------------------------------------------------------------------------
typedef void (^NDIFrameCallback)(CVPixelBufferRef pixelBuffer);

@interface NDICaptureSession : NSObject
/// Returns nil if the NDI runtime is not available.
- (nullable instancetype)initWithSource:(NDISource *)source;
- (void)startWithCallback:(NDIFrameCallback)callback;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
