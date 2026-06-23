#import "DeckLinkBridge.h"
#import "SDK/DeckLinkAPI.h"                       // base SDK 16.0 interfaces (IDeckLinkInput, …)
#import "SDK/DeckLinkAPIVideoInput_v14_2_1.h"     // v14_2_1 fallback for Desktop Video 14.x drivers
#import "SDK/DeckLinkAPIVideoFrame_v14_2_1.h"
#include <atomic>

// ============================================================================
// Runtime loading — finds the DeckLinkAPI.bundle installed by Desktop Video.
// This replaces DeckLinkAPIDispatch.cpp; only the SDK headers are needed.
// ============================================================================

static CFBundleRef getDeckLinkBundle(void) {
    static CFBundleRef sBundle = nullptr;
    static dispatch_once_t sOnce;
    dispatch_once(&sOnce, ^{
        // 1. Try by bundle ID (may already be loaded by the system extension)
        sBundle = CFBundleGetBundleWithIdentifier(
            CFSTR("com.blackmagic-design.desktopvideo.DeckLinkAPI"));
        if (sBundle) { CFRetain(sBundle); return; }

        // 2. Fall back to the known installation path
        CFURLRef url = CFURLCreateWithFileSystemPath(
            kCFAllocatorDefault,
            CFSTR("/Library/Application Support/Blackmagic Design/"
                  "Blackmagic DeckLink/DeckLinkAPI.bundle"),
            kCFURLPOSIXPathStyle, true);
        if (!url) return;
        sBundle = CFBundleCreate(kCFAllocatorDefault, url);
        CFRelease(url);
        if (sBundle && !CFBundleLoadExecutable(sBundle)) {
            CFRelease(sBundle);
            sBundle = nullptr;
        }
    });
    return sBundle;
}

// The DeckLinkAPI.bundle does NOT export the plain "CreateDeckLinkIteratorInstance"
// entry point — that name is synthesised by Blackmagic's DeckLinkAPIDispatch.cpp.
// The bundle instead exports versioned symbols ("..._0004", "..._0003", ...). Look
// them up highest-version-first, which is what the official dispatch does.
static void* lookupBundleFunction(CFBundleRef bundle, const char *const *names, int count) {
    for (int i = 0; i < count; i++) {
        CFStringRef s = CFStringCreateWithCString(kCFAllocatorDefault, names[i],
                                                  kCFStringEncodingUTF8);
        void *fn = (void *)CFBundleGetFunctionPointerForName(bundle, s);
        CFRelease(s);
        if (fn) return fn;
    }
    return nullptr;
}

static IDeckLinkIterator* createDeckLinkIterator(void) {
    CFBundleRef bundle = getDeckLinkBundle();
    if (!bundle) return nullptr;
    typedef IDeckLinkIterator* (*Fn)(void);
    static const char *const names[] = {
        "CreateDeckLinkIteratorInstance_0004",
        "CreateDeckLinkIteratorInstance_0003",
        "CreateDeckLinkIteratorInstance_0002",
        "CreateDeckLinkIteratorInstance",   // unversioned fallback
    };
    Fn fn = (Fn)lookupBundleFunction(bundle, names, 4);
    if (!fn) NSLog(@"[DeckLink] CreateDeckLinkIteratorInstance symbol not found in bundle");
    return fn ? fn() : nullptr;
}

// Logs the installed Desktop Video API version once, for diagnostics.
static void logDriverInfoOnce(void) {
    static dispatch_once_t sOnce;
    dispatch_once(&sOnce, ^{
        CFBundleRef bundle = getDeckLinkBundle();
        if (!bundle) { NSLog(@"[DeckLink] DeckLinkAPI.bundle NOT loaded"); return; }
        typedef IDeckLinkAPIInformation* (*Fn)(void);
        static const char *const names[] = {
            "CreateDeckLinkAPIInformationInstance_0001",
            "CreateDeckLinkAPIInformationInstance",   // unversioned fallback
        };
        Fn fn = (Fn)lookupBundleFunction(bundle, names, 2);
        IDeckLinkAPIInformation *info = fn ? fn() : nullptr;
        if (!info) { NSLog(@"[DeckLink] bundle loaded but API information unavailable"); return; }
        int64_t ver = 0;
        if (info->GetInt(BMDDeckLinkAPIVersion, &ver) == S_OK) {
            NSLog(@"[DeckLink] Desktop Video driver API version: %lld.%lld.%lld (0x%llX)",
                  (long long)((ver >> 24) & 0xFF), (long long)((ver >> 16) & 0xFF),
                  (long long)((ver >> 8) & 0xFF), (long long)ver);
        }
        info->Release();
    });
}

// ============================================================================
// DLDevice
// ============================================================================

@interface DLDevice ()
@property (nonatomic, assign) IDeckLink *deckLinkRef;   // kept alive via AddRef/Release
@end

@implementation DLDevice

- (instancetype)initWithDeckLink:(IDeckLink *)dl {
    if (!(self = [super init])) return nil;
    dl->AddRef();
    _deckLinkRef = dl;

    CFStringRef nameRef = nullptr;
    if (dl->GetDisplayName(&nameRef) == S_OK && nameRef) {
        _name = CFBridgingRelease(nameRef);
    } else {
        _name = @"Unknown DeckLink Device";
    }
    _deviceID = [NSString stringWithFormat:@"decklink::%@", _name];
    return self;
}

- (void)dealloc {
    if (_deckLinkRef) { _deckLinkRef->Release(); _deckLinkRef = nullptr; }
}

@end

// ============================================================================
// DLDeviceEnumerator
// ============================================================================

@implementation DLDeviceEnumerator

+ (BOOL)isAvailable {
    return getDeckLinkBundle() != nullptr;
}

+ (NSArray<DLDevice *> *)availableDevices {
    logDriverInfoOnce();
    NSMutableArray *result = [NSMutableArray array];
    IDeckLinkIterator *it = createDeckLinkIterator();
    if (!it) { NSLog(@"[DeckLink] iterator unavailable — 0 devices"); return result; }
    IDeckLink *dl = nullptr;
    while (it->Next(&dl) == S_OK) {
        [result addObject:[[DLDevice alloc] initWithDeckLink:dl]];
        dl->Release();
    }
    it->Release();
    NSLog(@"[DeckLink] availableDevices → %lu device(s)", (unsigned long)result.count);
    return result;
}

@end

// ============================================================================
// Input callback — templated over the interface generation so the same logic
// serves both the SDK 16.0 base interfaces and the v14_2_1 fallback.
// ============================================================================

// Candidate capture formats, tried in order. YUV first because capture-only
// devices (e.g. UltraStudio Recorder 3G) deliver the wire format natively and
// cannot do on-card conversion to RGB — asking for BGRA there yields frames
// permanently flagged bmdFrameHasNoInputSource. BGRA/ARGB remain as fallbacks
// for devices that DO support on-card conversion.
static const BMDPixelFormat kCandidateFormats[] = {
    bmdFormat8BitYUV,    // '2vuy' — kCVPixelFormatType_422YpCbCr8  (native, universal)
    bmdFormat10BitYUV,   // 'v210' — kCVPixelFormatType_422YpCbCr10 (native 10-bit)
    bmdFormat8BitBGRA,   // 'BGRA' — needs on-card conversion
    bmdFormat8BitARGB    // 'ARGB' — needs on-card conversion
};
static const int kCandidateFormatCount =
    (int)(sizeof(kCandidateFormats) / sizeof(kCandidateFormats[0]));

static OSType cvFormatFor(BMDPixelFormat f) {
    switch (f) {
        case bmdFormat8BitYUV:  return kCVPixelFormatType_422YpCbCr8;
        case bmdFormat10BitYUV: return kCVPixelFormatType_422YpCbCr10;
        case bmdFormat8BitARGB: return kCVPixelFormatType_32ARGB;
        case bmdFormat8BitBGRA:
        default:                return kCVPixelFormatType_32BGRA;
    }
}

// GetBytes moved from the video frame onto IDeckLinkVideoBuffer in SDK 16.0.
// These overloads invoke fn(bytes) while the frame data is valid, hiding the
// difference between the two interface generations.
template <typename Fn>
static void withFrameBytes(IDeckLinkVideoInputFrame_v14_2_1 *f, Fn fn) {
    void *bytes = nullptr;
    if (f->GetBytes(&bytes) == S_OK && bytes) fn(bytes);
}
template <typename Fn>
static void withFrameBytes(IDeckLinkVideoInputFrame *f, Fn fn) {
    IDeckLinkVideoBuffer *buf = nullptr;
    if (f->QueryInterface(IID_IDeckLinkVideoBuffer, (void **)&buf) != S_OK || !buf) return;
    if (buf->StartAccess(bmdBufferAccessRead) == S_OK) {
        void *bytes = nullptr;
        if (buf->GetBytes(&bytes) == S_OK && bytes) fn(bytes);
        buf->EndAccess(bmdBufferAccessRead);
    }
    buf->Release();
}

template <typename InputT, typename CallbackBaseT, typename FrameT>
class DLInputCallbackT : public CallbackBaseT {
public:
    InputT                     *inputRef;   // non-owning; the backend holds the ref
    DLFrameCallback             frameCallback;
    std::atomic<BMDPixelFormat> pixelFormat         { bmdFormat8BitYUV };
    BMDDisplayMode              configuredMode       { (BMDDisplayMode)0 };  // 0 = "not yet set"
    std::atomic<int>            formatIndex          { 0 };   // index into kCandidateFormats
    std::atomic<int>            consecutiveNoSource  { 0 };
    std::atomic<int>            goodFrameCount       { 0 };
    std::atomic<bool>           reconfiguring        { false };
    std::atomic<ULONG>          refCount             { 1 };

    // IOSurface-backed pool we copy frames into (zero-copy wrapping of DeckLink
    // frame bytes is fragile for packed YUV — CoreImage can deref null on it).
    // Accessed only from the single DeckLink frame-delivery thread.
    CVPixelBufferPoolRef        bufferPool { nullptr };
    long                        poolWidth  { 0 };
    long                        poolHeight { 0 };
    OSType                      poolFormat { 0 };

    DLInputCallbackT(InputT *input, DLFrameCallback cb)
        : inputRef(input), frameCallback(cb) {}

    ~DLInputCallbackT() {
        if (bufferPool) CVPixelBufferPoolRelease(bufferPool);
    }

    // Lazily (re)create the pool when the frame geometry/format changes.
    bool ensurePool(long w, long h, OSType fmt) {
        if (bufferPool && poolWidth == w && poolHeight == h && poolFormat == fmt)
            return true;
        if (bufferPool) { CVPixelBufferPoolRelease(bufferPool); bufferPool = nullptr; }

        NSDictionary *attrs = @{
            (id)kCVPixelBufferPixelFormatTypeKey     : @(fmt),
            (id)kCVPixelBufferWidthKey               : @(w),
            (id)kCVPixelBufferHeightKey              : @(h),
            (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
        };
        CVReturn r = CVPixelBufferPoolCreate(kCFAllocatorDefault, nullptr,
                                             (__bridge CFDictionaryRef)attrs, &bufferPool);
        if (r != kCVReturnSuccess) { bufferPool = nullptr; return false; }
        poolWidth = w; poolHeight = h; poolFormat = fmt;
        return true;
    }

    // Reconfigure the input to (mode, fmt) on a background thread. StopStreams must
    // NOT be called from within a DeckLink callback (deadlock), so we dispatch.
    // AddRef keeps this object alive until the block completes.
    void scheduleReconfigure(BMDDisplayMode mode, BMDPixelFormat fmt) {
        if (reconfiguring.exchange(true)) return;   // one reconfiguration at a time
        InputT *input = inputRef;
        AddRef();
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
            HRESULT hr = input->StopStreams();
            NSLog(@"[DLCapture BG] StopStreams:            0x%08X", (unsigned)hr);

            // No format-detection flag here: we already know the mode, and omitting it
            // stops VideoInputFormatChanged from re-firing after StartStreams.
            hr = input->EnableVideoInput(mode, fmt, bmdVideoInputFlagDefault);
            NSLog(@"[DLCapture BG] EnableVideoInput 0x%08X: 0x%08X", (unsigned)fmt, (unsigned)hr);

            if (hr == S_OK) {
                this->pixelFormat = fmt;
                hr = input->StartStreams();
                NSLog(@"[DLCapture BG] StartStreams:           0x%08X", (unsigned)hr);
            } else {
                NSLog(@"[DLCapture BG] EnableVideoInput failed — streams not restarted");
            }
            this->consecutiveNoSource = 0;
            this->reconfiguring = false;
            this->Release();
        });
    }

    // Called when format-detection identifies the incoming signal format.
    HRESULT VideoInputFormatChanged(BMDVideoInputFormatChangedEvents notificationEvents,
                                    IDeckLinkDisplayMode *newMode,
                                    BMDDetectedVideoInputFormatFlags detectedFlags) override {
        if (!inputRef) return S_OK;

        // Only act when the display mode itself changed — ignore field-dominance or
        // colorspace-only changes, and skip if we are already configured for this mode.
        if (!(notificationEvents & bmdVideoInputDisplayModeChanged)) return S_OK;

        BMDDisplayMode mode = newMode->GetDisplayMode();
        if (mode == configuredMode) return S_OK;
        configuredMode = mode;
        formatIndex    = 0;   // restart format search for the new mode

        NSLog(@"[DLCapture] Format detected → mode 0x%08X, flags 0x%08X — reconfiguring to 0x%08X",
              (unsigned)mode, (unsigned)detectedFlags, (unsigned)kCandidateFormats[0]);

        scheduleReconfigure(mode, kCandidateFormats[0]);
        return S_OK;
    }

    // Called for each captured frame. GetBytes lives directly on the frame
    // (inherited from IDeckLinkVideoFrame) in both interface generations.
    HRESULT VideoInputFrameArrived(FrameT *videoFrame,
                                   IDeckLinkAudioInputPacket *) override {
        if (!videoFrame || !frameCallback) return S_OK;

        if (videoFrame->GetFlags() & bmdFrameHasNoInputSource) {
            int n = ++consecutiveNoSource;
            if (n == 1 || (n % 120) == 0)
                NSLog(@"[DLCapture] no input source (consecutive %d, fmt 0x%08X)",
                      n, (unsigned)pixelFormat.load());

            // Adaptive fallback: if the source never locks with the current pixel
            // format, cycle to the next candidate. ~90 frames ≈ 3 s at 25–30 fps.
            if (n == 90 && configuredMode != 0 && !reconfiguring.load()) {
                int idx = (formatIndex.load() + 1) % kCandidateFormatCount;
                formatIndex = idx;
                NSLog(@"[DLCapture] source not locking — trying next pixel format 0x%08X",
                      (unsigned)kCandidateFormats[idx]);
                scheduleReconfigure(configuredMode, kCandidateFormats[idx]);
            }
            return S_OK;
        }

        consecutiveNoSource = 0;

        long width    = videoFrame->GetWidth();
        long height   = videoFrame->GetHeight();
        long rowBytes = videoFrame->GetRowBytes();

        withFrameBytes(videoFrame, [&](void *bytes) {
            int g = goodFrameCount.fetch_add(1);
            if (g < 5)
                NSLog(@"[DLCapture] GOOD frame %d: %ld×%ld rowBytes=%ld fmt=0x%08X",
                      g, width, height, rowBytes, (unsigned)pixelFormat.load());

            OSType cvFormat = cvFormatFor(pixelFormat.load());
            if (!ensurePool(width, height, cvFormat)) {
                if (g < 5) NSLog(@"[DLCapture] pool creation failed for fmt 0x%08X", (unsigned)cvFormat);
                return;
            }

            CVPixelBufferRef pb = nullptr;
            if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, bufferPool, &pb) != kCVReturnSuccess
                || !pb) {
                if (g < 5) NSLog(@"[DLCapture] pool buffer alloc failed");
                return;
            }

            // Copy DeckLink frame bytes into the pool buffer row by row (source and
            // destination strides may differ). All candidate formats are single-plane.
            CVPixelBufferLockBaseAddress(pb, 0);
            if (uint8_t *dst = (uint8_t *)CVPixelBufferGetBaseAddress(pb)) {
                size_t         dstStride = CVPixelBufferGetBytesPerRow(pb);
                size_t         copyBytes = (size_t)rowBytes < dstStride ? (size_t)rowBytes : dstStride;
                const uint8_t *src       = (const uint8_t *)bytes;
                for (long row = 0; row < height; row++)
                    memcpy(dst + row * dstStride, src + row * (size_t)rowBytes, copyBytes);
            }
            CVPixelBufferUnlockBaseAddress(pb, 0);

            frameCallback(pb);
            CVPixelBufferRelease(pb);
        });
        return S_OK;
    }

    ULONG   AddRef()  override { return ++refCount; }
    ULONG   Release() override { ULONG n = --refCount; if (n == 0) delete this; return n; }
    HRESULT QueryInterface(REFIID, LPVOID *ppv) override {
        if (ppv) *ppv = nullptr;
        return E_NOINTERFACE;
    }
};

// Concrete callback types for each supported interface generation.
typedef DLInputCallbackT<IDeckLinkInput, IDeckLinkInputCallback, IDeckLinkVideoInputFrame>
        DLInputCallback16;
typedef DLInputCallbackT<IDeckLinkInput_v14_2_1, IDeckLinkInputCallback_v14_2_1, IDeckLinkVideoInputFrame_v14_2_1>
        DLInputCallback14;

// ============================================================================
// Type-erased backend — keeps DLCaptureSession interface-version agnostic.
// We prefer the SDK 16.0 IDeckLinkInput; if the installed driver doesn't expose
// it (older Desktop Video), we fall back to the v14_2_1 interface.
// ============================================================================

struct DLBackend {
    virtual ~DLBackend() {}
    virtual void start(DLFrameCallback cb) = 0;
    virtual void stop() = 0;
};

template <typename InputT, typename CallbackT>
struct DLBackendT : DLBackend {
    InputT    *input;
    CallbackT *cb;
    explicit DLBackendT(InputT *in) : input(in), cb(nullptr) {}
    ~DLBackendT() override { stop(); if (input) { input->Release(); input = nullptr; } }

    void start(DLFrameCallback c) override {
        if (!input) return;
        cb = new CallbackT(input, c);
        input->SetCallback(cb);

        // Enable with format detection (native 8-bit YUV); the callback then
        // reconfigures to the detected mode and best pixel format.
        HRESULT hr = input->EnableVideoInput(bmdModeHD1080p30, bmdFormat8BitYUV,
                                             bmdVideoInputEnableFormatDetection);
        if (hr != S_OK) {
            const BMDDisplayMode modes[] = {
                bmdModeHD1080p25, bmdModeHD1080p2997, bmdModeHD1080p30,
                bmdModeHD1080i5994, bmdModeHD1080i50,
                bmdModeHD720p60, bmdModeHD720p50, bmdModeNTSC, bmdModePAL
            };
            for (auto &m : modes) {
                hr = input->EnableVideoInput(m, bmdFormat8BitYUV, bmdVideoInputFlagDefault);
                if (hr == S_OK) break;
            }
        }
        if (hr == S_OK) input->StartStreams();
        else NSLog(@"[DLCaptureSession] EnableVideoInput failed: 0x%08X", (unsigned)hr);
    }

    void stop() override {
        if (!input) return;
        input->StopStreams();
        input->DisableVideoInput();
        input->SetCallback(nullptr);
        if (cb) { cb->Release(); cb = nullptr; }
    }
};

typedef DLBackendT<IDeckLinkInput, DLInputCallback16>         DLBackend16;
typedef DLBackendT<IDeckLinkInput_v14_2_1, DLInputCallback14> DLBackend14;

// ============================================================================
// DLCaptureSession
// ============================================================================

@interface DLCaptureSession () {
    DLBackend *_backend;
}
@end

@implementation DLCaptureSession

- (nullable instancetype)initWithDevice:(DLDevice *)device {
    if (!(self = [super init])) return nil;

    // Re-enumerate for a fresh IDeckLink reference (avoids stale pointer issues).
    NSString *targetName = device.name;
    IDeckLinkIterator *it = createDeckLinkIterator();
    if (!it) { NSLog(@"[DLCaptureSession] DeckLink runtime not available"); return nil; }

    IDeckLink *foundDL = nullptr, *dl = nullptr;
    while (it->Next(&dl) == S_OK) {
        CFStringRef nameRef = nullptr;
        if (dl->GetDisplayName(&nameRef) == S_OK && nameRef) {
            NSString *name = CFBridgingRelease(nameRef);
            if ([name isEqualToString:targetName]) { foundDL = dl; break; }
        }
        dl->Release();
    }
    it->Release();

    if (!foundDL) {
        NSLog(@"[DLCaptureSession] Device '%@' not found", targetName);
        return nil;
    }

    // Prefer the SDK 16.0 interface (matches Desktop Video 16.x); fall back to
    // v14_2_1 for older drivers that don't expose the 16.0 IID.
    void *ptr = nullptr;
    HRESULT hr16 = foundDL->QueryInterface(IID_IDeckLinkInput, &ptr);
    if (hr16 == S_OK) {
        _backend = new DLBackend16((IDeckLinkInput *)ptr);
        NSLog(@"[DLCaptureSession] Using SDK 16.0 IDeckLinkInput interface");
    } else {
        HRESULT hr14 = foundDL->QueryInterface(IID_IDeckLinkInput_v14_2_1, &ptr);
        if (hr14 == S_OK) {
            _backend = new DLBackend14((IDeckLinkInput_v14_2_1 *)ptr);
            NSLog(@"[DLCaptureSession] IDeckLinkInput (16.0) unavailable (0x%08X) — using v14_2_1 fallback",
                  (unsigned)hr16);
        } else {
            NSLog(@"[DLCaptureSession] QueryInterface failed (16.0=0x%08X, v14_2_1=0x%08X)",
                  (unsigned)hr16, (unsigned)hr14);
            foundDL->Release();
            return nil;
        }
    }
    foundDL->Release();
    return self;
}

- (void)startWithCallback:(DLFrameCallback)callback {
    if (_backend) _backend->start(callback);
}

- (void)stop {
    if (_backend) _backend->stop();
}

- (void)dealloc {
    if (_backend) { delete _backend; _backend = nullptr; }
}

@end
