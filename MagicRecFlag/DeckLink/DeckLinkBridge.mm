#import "DeckLinkBridge.h"
#import "SDK/DeckLinkAPI.h"   // place DeckLinkAPI.h from the Desktop Video SDK here
#include <atomic>

// ============================================================================
// Runtime loading — we find DeckLinkAPI.bundle that Desktop Video installs.
// This replaces DeckLinkAPIDispatch.cpp so only the .h file is needed.
// ============================================================================

static CFBundleRef getDeckLinkBundle(void) {
    static CFBundleRef sBundle = nullptr;
    static dispatch_once_t sOnce;
    dispatch_once(&sOnce, ^{
        // 1. Try by bundle ID (may already be loaded by the system)
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
// Input callback (C++ COM object)
// ============================================================================

class DLInputCallbackImpl : public IDeckLinkInputCallback {
public:
    IDeckLinkInput   *inputRef;      // non-owning; DLCaptureSession holds the ref
    DLFrameCallback   frameCallback;
    std::atomic<ULONG> refCount { 1 };

    DLInputCallbackImpl(IDeckLinkInput *input, DLFrameCallback cb)
        : inputRef(input), frameCallback(cb) {}

    // Called when format detection identifies the incoming signal format.
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
    HRESULT VideoInputFrameArrived(IDeckLinkVideoInputFrame *videoFrame,
                                   IDeckLinkAudioInputPacket *) override {
        if (!videoFrame || !frameCallback) return S_OK;
        if (videoFrame->GetFlags() & bmdFrameHasNoInputSource) return S_OK;

        long width    = videoFrame->GetWidth();
        long height   = videoFrame->GetHeight();
        long rowBytes = videoFrame->GetRowBytes();
        void *bytes   = nullptr;
        if (videoFrame->GetBytes(&bytes) != S_OK || !bytes) return S_OK;

        // Wrap in a non-copying CVPixelBuffer — valid for the duration of this call.
        CVPixelBufferRef pb = nullptr;
        CVReturn status = CVPixelBufferCreateWithBytes(
            kCFAllocatorDefault,
            (size_t)width, (size_t)height,
            kCVPixelFormatType_32BGRA,
            bytes, (size_t)rowBytes,
            nullptr, nullptr, nullptr, &pb);

        if (status == kCVReturnSuccess && pb) {
            frameCallback(pb);          // synchronous — pb is still valid here
            CVPixelBufferRelease(pb);
        }
        return S_OK;
    }

    ULONG  AddRef()  override { return ++refCount; }
    ULONG  Release() override { ULONG n = --refCount; if (n == 0) delete this; return n; }
    HRESULT QueryInterface(REFIID, LPVOID *ppv) override {
        if (ppv) *ppv = nullptr;
        return E_NOINTERFACE;
    }
};

// ============================================================================
// DLCaptureSession
// ============================================================================

@interface DLCaptureSession () {
    IDeckLinkInput       *_input;
    DLInputCallbackImpl  *_cb;
}
@end

@implementation DLCaptureSession

- (nullable instancetype)initWithDevice:(DLDevice *)device {
    if (!(self = [super init])) return nil;
    IDeckLink *dl = device.deckLinkRef;
    if (!dl) return nil;
    void *ptr = nullptr;
    if (dl->QueryInterface(IID_IDeckLinkInput, &ptr) != S_OK) return nil;
    _input = (IDeckLinkInput *)ptr;   // QueryInterface already AddRef'd
    return self;
}

- (void)startWithCallback:(DLFrameCallback)callback {
    if (!_input) return;

    _cb = new DLInputCallbackImpl(_input, callback);
    _input->SetCallback(_cb);

    // Try with automatic format detection first; fall back to common HD modes.
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

    if (hr == S_OK) _input->StartStreams();
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
