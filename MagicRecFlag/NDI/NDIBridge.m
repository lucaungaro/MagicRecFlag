#import "NDIBridge.h"
#include <dlfcn.h>
#include <stdatomic.h>
#include <stdbool.h>

// ============================================================================
// Minimal NDI SDK declarations — the subset of Processing.NDI.structs.h /
// Find.h / Recv.h (NDI SDK v6, MIT-licensed headers) that this file uses.
// Only the runtime library is needed at run time; nothing is linked at build time.
// ============================================================================

typedef enum {
    NDIlib_frame_type_none          = 0,
    NDIlib_frame_type_video         = 1,
    NDIlib_frame_type_error         = 4,
    NDIlib_frame_type_status_change = 100,
    NDIlib_frame_type_max           = 0x7fffffff
} NDIlib_frame_type_e;

typedef enum {
    NDIlib_recv_bandwidth_highest = 100,
    NDIlib_recv_bandwidth_max     = 0x7fffffff
} NDIlib_recv_bandwidth_e;

typedef enum {
    NDIlib_recv_color_format_BGRX_BGRA = 0,   // frames always arrive as BGRX or BGRA
    NDIlib_recv_color_format_max       = 0x7fffffff
} NDIlib_recv_color_format_e;

typedef struct {
    const char *p_ndi_name;
    const char *p_url_address;
} NDIlib_source_t;

typedef struct {
    bool        show_local_sources;
    const char *p_groups;
    const char *p_extra_ips;
} NDIlib_find_create_t;

typedef struct {
    NDIlib_source_t            source_to_connect_to;
    NDIlib_recv_color_format_e color_format;
    NDIlib_recv_bandwidth_e    bandwidth;
    bool                       allow_video_fields;
    const char                *p_ndi_recv_name;
} NDIlib_recv_create_v3_t;

typedef struct {
    int         xres, yres;
    uint32_t    FourCC;
    int         frame_rate_N, frame_rate_D;
    float       picture_aspect_ratio;
    int         frame_format_type;
    int64_t     timecode;
    uint8_t    *p_data;
    int         line_stride_in_bytes;
    const char *p_metadata;
    int64_t     timestamp;
} NDIlib_video_frame_v2_t;

typedef void *NDIlib_find_instance_t;
typedef void *NDIlib_recv_instance_t;

// ============================================================================
// Runtime loading — finds the libndi.dylib installed by NDI Tools / the SDK.
// ============================================================================

typedef struct {
    bool                   (*initialize)(void);
    const char            *(*version)(void);
    NDIlib_find_instance_t (*find_create_v2)(const NDIlib_find_create_t *);
    bool                   (*find_wait_for_sources)(NDIlib_find_instance_t, uint32_t);
    const NDIlib_source_t *(*find_get_current_sources)(NDIlib_find_instance_t, uint32_t *);
    NDIlib_recv_instance_t (*recv_create_v3)(const NDIlib_recv_create_v3_t *);
    void                   (*recv_destroy)(NDIlib_recv_instance_t);
    NDIlib_frame_type_e    (*recv_capture_v2)(NDIlib_recv_instance_t, NDIlib_video_frame_v2_t *,
                                              void *audio, void *metadata, uint32_t timeout_ms);
    void                   (*recv_free_video_v2)(NDIlib_recv_instance_t, const NDIlib_video_frame_v2_t *);
} NDIRuntime;

static const NDIRuntime *getNDIRuntime(void) {
    static NDIRuntime sRuntime;
    static const NDIRuntime *sLoaded = NULL;
    static dispatch_once_t sOnce;
    dispatch_once(&sOnce, ^{
        // Same search order as the SDK's dynamic-loading sample: the runtime
        // directory variables first, then the standard install locations.
        NSMutableArray<NSString *> *paths = [NSMutableArray array];
        for (NSString *var in @[ @"NDI_RUNTIME_DIR_V6", @"NDI_RUNTIME_DIR_V5" ]) {
            const char *dir = getenv(var.UTF8String);
            if (dir) [paths addObject:[@(dir) stringByAppendingPathComponent:@"libndi.dylib"]];
        }
        [paths addObjectsFromArray:@[
            @"/usr/local/lib/libndi.dylib",
            @"/Library/NDI SDK for Apple/lib/macOS/libndi.dylib",
            @"/Library/NDI Advanced SDK for Apple/lib/macOS/libndi_advanced.dylib",
        ]];

        void *lib = NULL;
        for (NSString *p in paths) {
            lib = dlopen(p.fileSystemRepresentation, RTLD_LOCAL | RTLD_LAZY);
            if (lib) { NSLog(@"[NDI] runtime loaded from %@", p); break; }
        }
        if (!lib) { NSLog(@"[NDI] libndi.dylib NOT found — NDI sources unavailable"); return; }

#define NDI_SYM(field, name) \
        sRuntime.field = dlsym(lib, name); \
        if (!sRuntime.field) { NSLog(@"[NDI] symbol %s missing", name); return; }
        NDI_SYM(initialize,               "NDIlib_initialize")
        NDI_SYM(version,                  "NDIlib_version")
        NDI_SYM(find_create_v2,           "NDIlib_find_create_v2")
        NDI_SYM(find_wait_for_sources,    "NDIlib_find_wait_for_sources")
        NDI_SYM(find_get_current_sources, "NDIlib_find_get_current_sources")
        NDI_SYM(recv_create_v3,           "NDIlib_recv_create_v3")
        NDI_SYM(recv_destroy,             "NDIlib_recv_destroy")
        NDI_SYM(recv_capture_v2,          "NDIlib_recv_capture_v2")
        NDI_SYM(recv_free_video_v2,       "NDIlib_recv_free_video_v2")
#undef NDI_SYM

        if (!sRuntime.initialize()) {
            NSLog(@"[NDI] NDIlib_initialize failed (unsupported CPU?)");
            return;
        }
        NSLog(@"[NDI] runtime version: %s", sRuntime.version());
        sLoaded = &sRuntime;
    });
    return sLoaded;
}

// ============================================================================
// NDISource
// ============================================================================

@implementation NDISource

- (instancetype)initWithName:(NSString *)name {
    return [self initWithName:name urlAddress:nil];
}

- (instancetype)initWithName:(NSString *)name urlAddress:(nullable NSString *)url {
    if (!(self = [super init])) return nil;
    _name       = [name copy];
    _urlAddress = [url copy];
    _sourceID   = [NSString stringWithFormat:@"ndi::%@", _name];
    return self;
}

@end

// ============================================================================
// NDISourceFinder
// ============================================================================

@implementation NDISourceFinder

+ (BOOL)isAvailable {
    return getNDIRuntime() != NULL;
}

+ (NSArray<NDISource *> *)availableSourcesWithTimeout:(uint32_t)timeoutMs {
    const NDIRuntime *ndi = getNDIRuntime();
    if (!ndi) return @[];

    // One finder for the app's lifetime: discovery keeps running between
    // refreshes, so later calls answer immediately. The pointer returned by
    // find_get_current_sources is only valid until the next call, hence the lock.
    static NDIlib_find_instance_t sFinder = NULL;
    @synchronized (self) {
        if (!sFinder) {
            NDIlib_find_create_t settings = { .show_local_sources = true };
            sFinder = ndi->find_create_v2(&settings);
            if (!sFinder) { NSLog(@"[NDI] find_create_v2 failed"); return @[]; }

            // First call: wait for the first announcements, then keep collecting
            // while new ones still arrive in quick succession.
            if (ndi->find_wait_for_sources(sFinder, timeoutMs)) {
                while (ndi->find_wait_for_sources(sFinder, 300)) {}
            }
        }

        uint32_t count = 0;
        const NDIlib_source_t *sources = ndi->find_get_current_sources(sFinder, &count);
        NSMutableArray *result = [NSMutableArray arrayWithCapacity:count];
        for (uint32_t i = 0; i < count; i++) {
            if (!sources[i].p_ndi_name) continue;
            NSString *url = sources[i].p_url_address ? @(sources[i].p_url_address) : nil;
            [result addObject:[[NDISource alloc] initWithName:@(sources[i].p_ndi_name)
                                                   urlAddress:url]];
        }
        NSLog(@"[NDI] availableSources → %u source(s)", count);
        return result;
    }
}

@end

// ============================================================================
// NDICaptureSession
// ============================================================================

@interface NDICaptureSession () {
    NDISource             *_source;
    NDIlib_recv_instance_t _recv;
    atomic_bool            _stopRequested;
    dispatch_semaphore_t   _finished;   // non-nil while running; signalled when the thread exits

    // IOSurface-backed pool we copy frames into; NDI frame memory is only valid
    // until recv_free_video_v2. Accessed only from the receive thread.
    CVPixelBufferPoolRef   _bufferPool;
    int                    _poolWidth, _poolHeight;
}
@end

@implementation NDICaptureSession

- (nullable instancetype)initWithSource:(NDISource *)source {
    if (!getNDIRuntime()) { NSLog(@"[NDICaptureSession] NDI runtime not available"); return nil; }
    if (!(self = [super init])) return nil;
    _source = source;
    return self;
}

- (void)startWithCallback:(NDIFrameCallback)callback {
    const NDIRuntime *ndi = getNDIRuntime();
    if (!ndi || _finished) return;   // already running

    NDIlib_recv_create_v3_t settings = {
        .source_to_connect_to = {
            .p_ndi_name    = _source.name.UTF8String,
            .p_url_address = _source.urlAddress.UTF8String,
        },
        .color_format       = NDIlib_recv_color_format_BGRX_BGRA,
        .bandwidth          = NDIlib_recv_bandwidth_highest,
        .allow_video_fields = false,
        .p_ndi_recv_name    = "Magic Rec Flag",
    };
    _recv = ndi->recv_create_v3(&settings);
    if (!_recv) { NSLog(@"[NDICaptureSession] recv_create_v3 failed for '%@'", _source.name); return; }
    NSLog(@"[NDICaptureSession] receiving from '%@'", _source.name);

    atomic_store(&_stopRequested, false);
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    _finished = finished;

    NSThread *thread = [[NSThread alloc] initWithBlock:^{
        [self receiveLoop:ndi callback:callback];
        dispatch_semaphore_signal(finished);
    }];
    thread.name = @"com.magicrecflag.ndi.receive";
    thread.qualityOfService = NSQualityOfServiceUserInteractive;
    [thread start];
}

- (void)receiveLoop:(const NDIRuntime *)ndi callback:(NDIFrameCallback)callback {
    int goodFrames = 0;
    while (!atomic_load(&_stopRequested)) {
        NDIlib_video_frame_v2_t frame = { 0 };
        // Short timeout so stop() never waits long.
        NDIlib_frame_type_e type = ndi->recv_capture_v2(_recv, &frame, NULL, NULL, 100);
        if (type == NDIlib_frame_type_error) {
            NSLog(@"[NDICaptureSession] connection lost");
            continue;
        }
        if (type != NDIlib_frame_type_video) continue;

        if (goodFrames < 5)
            NSLog(@"[NDICaptureSession] frame %d: %d×%d stride=%d fourcc=%.4s",
                  goodFrames, frame.xres, frame.yres, frame.line_stride_in_bytes,
                  (const char *)&frame.FourCC);
        goodFrames++;

        CVPixelBufferRef pb = [self copyFrame:&frame];
        ndi->recv_free_video_v2(_recv, &frame);
        if (pb) {
            callback(pb);
            CVPixelBufferRelease(pb);
        }
    }

    ndi->recv_destroy(_recv);
    _recv = NULL;
    if (_bufferPool) { CVPixelBufferPoolRelease(_bufferPool); _bufferPool = NULL; }
}

// Copies a BGRA/BGRX NDI frame into a pool buffer, row by row (strides may differ).
- (nullable CVPixelBufferRef)copyFrame:(const NDIlib_video_frame_v2_t *)frame CF_RETURNS_RETAINED {
    if (!frame->p_data || frame->xres <= 0 || frame->yres <= 0) return NULL;

    if (!_bufferPool || _poolWidth != frame->xres || _poolHeight != frame->yres) {
        if (_bufferPool) { CVPixelBufferPoolRelease(_bufferPool); _bufferPool = NULL; }
        NSDictionary *attrs = @{
            (id)kCVPixelBufferPixelFormatTypeKey     : @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferWidthKey               : @(frame->xres),
            (id)kCVPixelBufferHeightKey              : @(frame->yres),
            (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
        };
        if (CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL, (__bridge CFDictionaryRef)attrs,
                                    &_bufferPool) != kCVReturnSuccess) {
            _bufferPool = NULL;
            return NULL;
        }
        _poolWidth  = frame->xres;
        _poolHeight = frame->yres;
    }

    CVPixelBufferRef pb = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _bufferPool, &pb) != kCVReturnSuccess
        || !pb) return NULL;

    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t *dst = CVPixelBufferGetBaseAddress(pb);
    if (dst) {
        size_t dstStride = CVPixelBufferGetBytesPerRow(pb);
        size_t srcStride = (size_t)frame->line_stride_in_bytes;
        size_t copyBytes = MIN((size_t)frame->xres * 4, MIN(srcStride, dstStride));
        for (int row = 0; row < frame->yres; row++)
            memcpy(dst + row * dstStride, frame->p_data + row * srcStride, copyBytes);
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
    return pb;
}

- (void)stop {
    dispatch_semaphore_t finished = _finished;
    if (!finished) return;
    _finished = nil;
    atomic_store(&_stopRequested, true);
    dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
}

- (void)dealloc {
    [self stop];
}

@end
