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

class DLInputCallbackImpl : public IDeckLinkInputCallback_v14_2_1 {
public:
    IDeckLinkInput_v14_2_1 *inputRef;   // non-owning; DLCaptureSession holds the ref
    DLFrameCallback          frameCallback;
    std::atomic<ULONG>       refCount { 1 };

    DLInputCallbackImpl(IDeckLinkInput_v14_2_1 *input, DLFrameCallback cb)
        : inputRef(input), frameCallback(cb) {}

    // Called when format-detection identifies a new signal format.
    HRESULT VideoInputFormatChanged(BMDVideoInputFormatChangedEvents,
                                    IDeckLinkDisplayMode *newMode,
                                    BMDDetectedVideoInputFormatFlags) override {
        if (!inputRef) return S_OK;
        inputRef->PauseStreams();
        inputRef->FlushStreams();
        inputRef->EnableVideoInput(newMode->GetDisplayMode(),
                                   bmdFormat8BitBGRA,
                                   bmdVideoInputEnableFormatDetection);
        inputRef->StartStreams();
        return S_OK;
    }

    // Called for each captured frame.
    // In Desktop Video ≤ 14.x, GetBytes lives directly on the frame.
    HRESULT VideoInputFrameArrived(IDeckLinkVideoInputFrame_v14_2_1 *videoFrame,
                                   IDeckLinkAudioInputPacket *) override {
        if (!videoFrame || !frameCallback) return S_OK;
        if (videoFrame->GetFlags() & bmdFrameHasNoInputSource) return S_OK;

        long   width    = videoFrame->GetWidth();
        long   height   = videoFrame->GetHeight();
        long   rowBytes = videoFrame->GetRowBytes();
        void  *bytes    = nullptr;
        if (videoFrame->GetBytes(&bytes) != S_OK || !bytes) return S_OK;

        CVPixelBufferRef pb = nullptr;
        CVReturn status = CVPixelBufferCreateWithBytes(
            kCFAllocatorDefault,
            (size_t)width, (size_t)height,
            kCVPixelFormatType_32BGRA,
            bytes, (size_t)rowBytes,
            nullptr, nullptr, nullptr, &pb);

        if (status == kCVReturnSuccess && pb) {
            frameCallback(pb);
            CVPixelBufferRelease(pb);
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

    // Try automatic format detection first; fall back to common HD modes.
    HRESULT hr = _input->EnableVideoInput(bmdModeHD1080p30,
                                          bmdFormat8BitBGRA,
                                          bmdVideoInputEnableFormatDetection);
    if (hr != S_OK) {
        const BMDDisplayMode modes[] = {
            bmdModeHD1080p25,   bmdModeHD1080p2997, bmdModeHD1080p30,
            bmdModeHD1080i5994, bmdModeHD1080i50,
            bmdModeHD720p60,    bmdModeHD720p50,
            bmdModeNTSC,        bmdModePAL
        };
        for (auto &m : modes) {
            hr = _input->EnableVideoInput(m, bmdFormat8BitBGRA, bmdVideoInputFlagDefault);
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
