/**
 * @file src/platform/macos/av_video.h
 * @brief Declarations for video capture on macOS.
 */
#pragma once

// platform includes
#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>

/**
 * @brief macOS capture session and video output handles.
 */
struct CaptureSession {
  AVCaptureVideoDataOutput *output;  ///< Output.
  NSCondition *captureStopped;  ///< Capture stopped.
};

/**
 * @brief AVFoundation video capture controller used by the macOS backend.
 */
@interface AVVideo: NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>

/**
 * @brief Display ID property.
 */
@property (nonatomic, assign) CGDirectDisplayID displayID;
/**
 * @brief Min frame duration property.
 */
@property (nonatomic, assign) CMTime minFrameDuration;
/**
 * @brief Pixel format property.
 */
@property (nonatomic, assign) OSType pixelFormat;
/**
 * @brief Frame width property.
 */
@property (nonatomic, assign) int frameWidth;
/**
 * @brief Frame height property.
 */
@property (nonatomic, assign) int frameHeight;

/**
 * @brief Objective-C block invoked for each captured sample buffer.
 */
typedef bool (^FrameCallbackBlock)(CMSampleBufferRef);

/**
 * @brief Capture session that owns the active AVFoundation inputs and outputs.
 */
@property (nonatomic, assign) AVCaptureSession *session;
/**
 * @brief Video outputs property.
 */
@property (nonatomic, assign) NSMapTable<AVCaptureConnection *, AVCaptureVideoDataOutput *> *videoOutputs;
/**
 * @brief Capture callbacks property.
 */
@property (nonatomic, assign) NSMapTable<AVCaptureConnection *, FrameCallbackBlock> *captureCallbacks;
/**
 * @brief Capture signals property.
 */
@property (nonatomic, assign) NSMapTable<AVCaptureConnection *, dispatch_semaphore_t> *captureSignals;

/**
 * @brief Initialize AVFoundation capture for a display and frame rate.
 *
 * @param displayID Display ID.
 * @param frameRate Frame rate.
 * @return Initialized AVVideo instance, or nil on failure.
 */
- (id)initWithDisplay:(CGDirectDisplayID)displayID frameRate:(int)frameRate;

/**
 * @brief Find a video capture device (a capture card / camera) by name.
 *
 * Matches, case-insensitively, a device whose localized name or unique id contains the needle.
 * This selects a capture card feeding another device's screen (e.g. a phone over HDMI) as the
 * capture source instead of a display.
 *
 * @param needle Substring to match against device localized name or unique id.
 * @return The matching AVCaptureDevice, or nil if none matches.
 */
+ (AVCaptureDevice *)captureDeviceMatching:(NSString *)needle;

/**
 * @brief Enumerate external video-capture devices (capture cards).
 *
 * Returns external capture devices (e.g. a capture card carrying a phone's HDMI output), excluding
 * the built-in and Continuity cameras, so they can be offered as switchable capture sources in
 * display_names(). Enumeration does not open the devices and needs no camera permission.
 *
 * @return Array of external AVCaptureDevices (possibly empty).
 */
+ (NSArray<AVCaptureDevice *> *)captureDevices;

/**
 * @brief Initialize AVFoundation capture from a video capture device rather than a display.
 *
 * Frame size is taken from the device's active format. The capture, callback and teardown path is
 * shared with the display case; only the session input differs.
 *
 * @param device The capture device to stream from.
 * @param frameRate Frame rate.
 * @return Initialized AVVideo instance, or nil on failure.
 */
- (id)initWithCaptureDevice:(AVCaptureDevice *)device frameRate:(int)frameRate;

/**
 * @brief Set frame width frame height.
 *
 * @param frameWidth Frame width.
 * @param frameHeight Frame height.
 */
- (void)setFrameWidth:(int)frameWidth frameHeight:(int)frameHeight;
/**
 * @brief Run the capture loop for this backend.
 *
 * @param frameCallback Frame callback.
 * @return Capture status reported to the streaming pipeline.
 */
- (dispatch_semaphore_t)capture:(FrameCallbackBlock)frameCallback;

/**
 * @brief Abandon a capture that has not ended on its own.
 *
 * The frame callback normally tears its own capture down by returning false. When the
 * caller gives up on a capture that stopped delivering frames, such as after the display
 * slept, this performs that teardown on its behalf.
 *
 * @param signal Semaphore previously returned by capture:.
 */
- (void)stopCapture:(dispatch_semaphore_t)signal;

@end
