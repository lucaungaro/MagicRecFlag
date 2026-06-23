#import "DeckLinkBridge.h"
#import "SDK/DeckLinkAPI.h"
#import "SDK/DeckLinkAPIVideoInput_v14_2_1.h"   // IDeckLinkInput_v14_2_1, IDeckLinkInputCallback_v14_2_1
#import "SDK/DeckLinkAPIVideoFrame_v14_2_1.h"   // IDeckLinkVideoInputFrame_v14_2_1 (GetBytes on frame)
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

static IDeckLinkIterator* createDeckLinkIterator(void) {
    CFBundleRef bundle = getDeckLinkBundle();
    if (!bundle) return nullptr;
    typedef IDeckLinkIterator* (*Fn)(void);
    Fn fn = (Fn)CFBundleGetFunctionPointerForName(
        bundle, CFSTR("CreateDeckLinkIteratorInstance"));
    return fn ? fn() : nullptr;
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
    NSMutableArray *result = [NSMutableArray array];
    IDeckLinkIterator *it = createDeckLinkIterator();
    if (!it) return result;
    IDeckLink *dl = nullptr;
    while (it->Next(&dl) == S_OK) {
        [result addObject:[[DLDevice alloc] initWithDeckLink:dl]];
        dl->Release();
    }
    it->Release();
    return result;
}

@end

// ============================================================================
// Input callback — uses v14_2_1 interfaces to match the installed driver
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

class DLInputCallbackImpl : public IDeckLinkInputCallback_v14_2_1 {
public:
    IDeckLinkInput_v14_2_1     *inputRef;   // non-owning; DLCaptureSession holds the ref
    DLFrameCallback             frameCallback;
    std::atomic<BMDPixelFormat> pixelFormat         { bmdFormat8BitYUV };
    BMDDisplayMode              configuredMode       { (BMDDisplayMode)0 };  // 0 = "not yet set"
    std::atomic<int>            formatIndex          { 0 };   // index into kCandidateFormats
    std::atomic<int>            consecutiveNoSource  { 0 };
    std::atomic<int>            goodFrameCount       { 0 };
    std::atomic<bool>           reconfiguring        { false };
    std::atomic<ULONG>          refCount             { 1 };

    DLInputCallbackImpl(IDeckLinkInput_v14_2_1 *input, DLFrameCallback cb)
        : inputRef(input), frameCallback(cb) {}

    // Reconfigure the input to (mode, fmt) on a background thread. StopStreams must
    // NOT be called from within a DeckLink callback (deadlock), so we dispatch.
    // AddRef keeps this object alive until the block completes.
    void scheduleReconfigure(BMDDisplayMode mode, BMDPixelFormat fmt) {
        if (reconfiguring.exchange(true)) return;   // one reconfiguration at a time
        IDeckLinkInput_v14_2_1 *input = inputRef;
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

    // Called for each captured frame.
    // In Desktop Video ≤ 14.x, GetBytes lives directly on the frame.
    HRESULT VideoInputFrameArrived(IDeckLinkVideoInputFrame_v14_2_1 *videoFrame,
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

        long   width    = videoFrame->GetWidth();
        long   height   = videoFrame->GetHeight();
        long   rowBytes = videoFrame->GetRowBytes();
        void  *bytes    = nullptr;
        if (videoFrame->GetBytes(&bytes) != S_OK || !bytes) return S_OK;

        int g = goodFrameCount.fetch_add(1);
        if (g < 5)
            NSLog(@"[DLCapture] GOOD frame %d: %ld×%ld rowBytes=%ld fmt=0x%08X",
                  g, width, height, rowBytes, (unsigned)pixelFormat.load());

        OSType cvFormat = cvFormatFor(pixelFormat.load());

        CVPixelBufferRef pb = nullptr;
        CVReturn status = CVPixelBufferCreateWithBytes(
            kCFAllocatorDefault,
            (size_t)width, (size_t)height,
            cvFormat,
            bytes, (size_t)rowBytes,
            nullptr, nullptr, nullptr, &pb);

        if (status == kCVReturnSuccess && pb) {
            frameCallback(pb);
            CVPixelBufferRelease(pb);
        } else if (g < 5) {
            NSLog(@"[DLCapture] CVPixelBufferCreateWithBytes failed: %d", (int)status);
        }
        return S_OK;
    }

    ULONG   AddRef()  override { return ++refCount; }
    ULONG   Release() override { ULONG n = --refCount; if (n == 0) delete this; return n; }
    HRESULT QueryInterface(REFIID, LPVOID *ppv) override {
        if (ppv) *ppv = nullptr;
        return E_NOINTERFACE;
    }
};

// ============================================================================
// DLCaptureSession
// ============================================================================

@interface DLCaptureSession () {
    IDeckLinkInput_v14_2_1 *_input;
    DLInputCallbackImpl     *_cb;
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

    // Query for the v14_2_1 input interface — compatible with Desktop Video 14.x and later.
    void *ptr  = nullptr;
    HRESULT hr = foundDL->QueryInterface(IID_IDeckLinkInput_v14_2_1, &ptr);
    foundDL->Release();

    if (hr != S_OK) {
        NSLog(@"[DLCaptureSession] QueryInterface(IDeckLinkInput_v14_2_1) failed: 0x%08X", (unsigned)hr);
        return nil;
    }

    _input = (IDeckLinkInput_v14_2_1 *)ptr;
    return self;
}

- (void)startWithCallback:(DLFrameCallback)callback {
    if (!_input) return;

    _cb = new DLInputCallbackImpl(_input, callback);
    _input->SetCallback(_cb);

    // Enable with format detection so VideoInputFormatChanged fires and tells us the
    // real signal mode; capture in native 8-bit YUV (works on capture-only devices
    // that can't convert to RGB on-card). The detection callback then reconfigures
    // to the detected mode and best pixel format.
    HRESULT hr = _input->EnableVideoInput(bmdModeHD1080p30,
                                          bmdFormat8BitYUV,
                                          bmdVideoInputEnableFormatDetection);
    if (hr != S_OK) {
        const BMDDisplayMode modes[] = {
            bmdModeHD1080p25,   bmdModeHD1080p2997, bmdModeHD1080p30,
            bmdModeHD1080i5994, bmdModeHD1080i50,
            bmdModeHD720p60,    bmdModeHD720p50,
            bmdModeNTSC,        bmdModePAL
        };
        for (auto &m : modes) {
            hr = _input->EnableVideoInput(m, bmdFormat8BitYUV, bmdVideoInputFlagDefault);
            if (hr == S_OK) break;
        }
    }

    if (hr == S_OK) {
        _input->StartStreams();
    } else {
        NSLog(@"[DLCaptureSession] EnableVideoInput failed: 0x%08X", (unsigned)hr);
    }
}

- (void)stop {
    if (!_input) return;
    _input->StopStreams();
    _input->DisableVideoInput();
    _input->SetCallback(nullptr);
    if (_cb) { _cb->Release(); _cb = nullptr; }
}

- (void)dealloc {
    [self stop];
    if (_input) { _input->Release(); _input = nullptr; }
}

@end
