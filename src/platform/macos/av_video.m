/**
 * @file src/platform/macos/av_video.m
 * @brief Definitions for video capture on macOS.
 */
// local includes
#import "av_video.h"

@implementation AVVideo

- (id)initWithDisplay:(CGDirectDisplayID)displayID frameRate:(int)frameRate {
  self = [super init];

  CGDisplayModeRef mode = CGDisplayCopyDisplayMode(displayID);
  if (!mode) {
    [self release];
    return nil;
  }

  self.displayID = displayID;
  self.pixelFormat = kCVPixelFormatType_32BGRA;
  self.frameWidth = (int) CGDisplayModeGetPixelWidth(mode);
  self.frameHeight = (int) CGDisplayModeGetPixelHeight(mode);
  self.minFrameDuration = CMTimeMake(1, frameRate);
  self.session = [[AVCaptureSession alloc] init];
  self.videoOutputs = [[NSMapTable alloc] init];
  self.captureCallbacks = [[NSMapTable alloc] init];
  self.captureSignals = [[NSMapTable alloc] init];

  CFRelease(mode);

  AVCaptureScreenInput *screenInput = [[AVCaptureScreenInput alloc] initWithDisplayID:self.displayID];
  [screenInput setMinFrameDuration:self.minFrameDuration];

  if ([self.session canAddInput:screenInput]) {
    [self.session addInput:screenInput];
  } else {
    [screenInput release];
    return nil;
  }

  [self.session startRunning];

  return self;
}

+ (AVCaptureDevice *)captureDeviceMatching:(NSString *)needle {
  if (needle.length == 0) {
    return nil;
  }
  // devicesWithMediaType: is deprecated but is the simplest call that still returns external
  // capture cards across the SDK versions we build against. A substring match on the localized
  // name keeps the config readable ("Cam Link 4K") instead of demanding a unique id.
  NSArray<AVCaptureDevice *> *devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
  for (AVCaptureDevice *device in devices) {
    if ([device.localizedName rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [device.uniqueID rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound) {
      return device;
    }
  }
  return nil;
}

- (id)initWithCaptureDevice:(AVCaptureDevice *)device frameRate:(int)frameRate {
  self = [super init];

  if (!device) {
    [self release];
    return nil;
  }

  NSError *error = nil;
  AVCaptureDeviceInput *deviceInput = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
  if (!deviceInput) {
    [self release];
    return nil;
  }

  // Frame size comes from the device's active format, the resolution the card is actually
  // delivering (e.g. the HDMI mode of the phone plugged into it).
  CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription);

  self.displayID = 0;  // not a display
  self.pixelFormat = kCVPixelFormatType_32BGRA;
  self.frameWidth = (int) dims.width;
  self.frameHeight = (int) dims.height;
  self.minFrameDuration = CMTimeMake(1, frameRate);
  self.session = [[AVCaptureSession alloc] init];
  self.videoOutputs = [[NSMapTable alloc] init];
  self.captureCallbacks = [[NSMapTable alloc] init];
  self.captureSignals = [[NSMapTable alloc] init];

  // InputPriority: keep the device's own active format rather than letting the session pick a
  // preset, so frameWidth/frameHeight above match what actually arrives.
  self.session.sessionPreset = AVCaptureSessionPresetInputPriority;

  if ([self.session canAddInput:deviceInput]) {
    [self.session addInput:deviceInput];
  } else {
    return nil;
  }

  [self.session startRunning];

  return self;
}

- (void)dealloc {
  [self.videoOutputs release];
  [self.captureCallbacks release];
  [self.captureSignals release];
  [self.session stopRunning];
  [super dealloc];
}

- (void)setFrameWidth:(int)frameWidth frameHeight:(int)frameHeight {
  self.frameWidth = frameWidth;
  self.frameHeight = frameHeight;
}

- (dispatch_semaphore_t)capture:(FrameCallbackBlock)frameCallback {
  @synchronized(self) {
    AVCaptureVideoDataOutput *videoOutput = [[AVCaptureVideoDataOutput alloc] init];

    [videoOutput setVideoSettings:@{
      (NSString *) kCVPixelBufferPixelFormatTypeKey: [NSNumber numberWithUnsignedInt:self.pixelFormat],
      (NSString *) kCVPixelBufferWidthKey: [NSNumber numberWithInt:self.frameWidth],
      (NSString *) kCVPixelBufferHeightKey: [NSNumber numberWithInt:self.frameHeight],
      (NSString *) AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
    }];

    dispatch_queue_attr_t qos = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, DISPATCH_QUEUE_PRIORITY_HIGH);
    dispatch_queue_t recordingQueue = dispatch_queue_create("videoCaptureQueue", qos);
    [videoOutput setSampleBufferDelegate:self queue:recordingQueue];

    [self.session stopRunning];

    if ([self.session canAddOutput:videoOutput]) {
      [self.session addOutput:videoOutput];
    } else {
      [videoOutput release];
      return nil;
    }

    AVCaptureConnection *videoConnection = [videoOutput connectionWithMediaType:AVMediaTypeVideo];
    dispatch_semaphore_t signal = dispatch_semaphore_create(0);

    [self.videoOutputs setObject:videoOutput forKey:videoConnection];
    [self.captureCallbacks setObject:frameCallback forKey:videoConnection];
    [self.captureSignals setObject:signal forKey:videoConnection];

    [self.session startRunning];

    return signal;
  }
}

- (void)stopCapture:(dispatch_semaphore_t)signal {
  @synchronized(self) {
    AVCaptureConnection *target = nil;
    for (AVCaptureConnection *connection in self.captureSignals) {
      if ([self.captureSignals objectForKey:connection] == signal) {
        target = connection;
        break;
      }
    }

    if (target == nil) {
      return;
    }

    // Same teardown the frame callback performs when it returns false. Leaving the output
    // in the session while the map tables release it over-releases it once this object is
    // deallocated, so the entries have to go before the caller drops us.
    [self.session stopRunning];
    [self.captureCallbacks removeObjectForKey:target];
    [self.session removeOutput:[self.videoOutputs objectForKey:target]];
    [self.videoOutputs removeObjectForKey:target];
    [self.captureSignals removeObjectForKey:target];
    [self.session startRunning];
  }
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput
  didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
         fromConnection:(AVCaptureConnection *)connection {
  FrameCallbackBlock callback = [self.captureCallbacks objectForKey:connection];

  if (callback != nil) {
    if (!callback(sampleBuffer)) {
      @synchronized(self) {
        [self.session stopRunning];
        [self.captureCallbacks removeObjectForKey:connection];
        [self.session removeOutput:[self.videoOutputs objectForKey:connection]];
        [self.videoOutputs removeObjectForKey:connection];
        dispatch_semaphore_signal([self.captureSignals objectForKey:connection]);
        [self.captureSignals removeObjectForKey:connection];
        [self.session startRunning];
      }
    }
  }
}

@end
