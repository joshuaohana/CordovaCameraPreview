#import "CameraViewController.h"
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AssetsLibrary/AssetsLibrary.h>
#import "AVCamPreviewView.h"

static void * CapturingStillImageContext = &CapturingStillImageContext;
static void * SessionRunningAndDeviceAuthorizedContext = &SessionRunningAndDeviceAuthorizedContext;

@implementation CameraViewController

- (BOOL)isSessionRunningAndDeviceAuthorized
{
    return [[self session] isRunning] && [self isDeviceAuthorized];
}

+ (NSSet *)keyPathsForValuesAffectingSessionRunningAndDeviceAuthorized
{
    return [NSSet setWithObjects:@"session.running", @"deviceAuthorized", nil];
}

- (id)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil {
	self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil];
	return self;
}

- (void)viewDidLoad{
    [super viewDidLoad];
    self.view.userInteractionEnabled = FALSE;
    
     // Create the AVCaptureSession
     AVCaptureSession *session = [[AVCaptureSession alloc] init];
     [self setSession:session];
     
     // Setup the preview view
     [[self previewView] setSession:session];
     
     // Check for device authorization
     [self checkDeviceAuthorizationStatus];
     
     dispatch_queue_t sessionQueue = dispatch_queue_create("session queue", DISPATCH_QUEUE_SERIAL);
     [self setSessionQueue:sessionQueue];
     
     dispatch_async(sessionQueue, ^{
        [self setBackgroundRecordingID:UIBackgroundTaskInvalid];
        
        NSError *error = nil;
        
        AVCaptureDevice *videoDevice = [CameraViewController deviceWithMediaType:AVMediaTypeVideo preferringPosition:AVCaptureDevicePositionBack];
        AVCaptureDeviceInput *videoDeviceInput = [AVCaptureDeviceInput deviceInputWithDevice:videoDevice error:&error];
        
        if (error){
            NSLog(@"%@", error);
        }
        
        if ([session canAddInput:videoDeviceInput])
        {
            [session addInput:videoDeviceInput];
            [self setVideoDeviceInput:videoDeviceInput];
            
            dispatch_async(dispatch_get_main_queue(), ^{
                [[(AVCaptureVideoPreviewLayer *)[[self previewView] layer] connection] setVideoOrientation:(AVCaptureVideoOrientation)[self interfaceOrientation]];
            });
        }
        
        AVCaptureStillImageOutput *stillImageOutput = [[AVCaptureStillImageOutput alloc] init];
        if ([session canAddOutput:stillImageOutput])
        {
            [stillImageOutput setOutputSettings:@{AVVideoCodecKey : AVVideoCodecJPEG}];
            [session addOutput:stillImageOutput];
            [self setStillImageOutput:stillImageOutput];
        }
    });
    
    if (![UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypeCamera]) {
        UIAlertView *alertView = [[UIAlertView alloc] initWithTitle:@"Error" message:@"Camera not found!" delegate:nil cancelButtonTitle:@"OK" otherButtonTitles: nil];
        [alertView show];
    }
}

- (void)viewDidAppear:(BOOL)animated{
    [[UIApplication sharedApplication] setStatusBarHidden:YES withAnimation:UIStatusBarAnimationFade];
}

- (void)viewDidDisappear:(BOOL)animated {
    
    dispatch_async([self sessionQueue], ^{
        [[self session] stopRunning];
        
        [[NSNotificationCenter defaultCenter] removeObserver:self name:AVCaptureDeviceSubjectAreaDidChangeNotification object:[[self videoDeviceInput] device]];
        [[NSNotificationCenter defaultCenter] removeObserver:[self runtimeErrorHandlingObserver]];
        
        [self removeObserver:self forKeyPath:@"sessionRunningAndDeviceAuthorized" context:SessionRunningAndDeviceAuthorizedContext];
        [self removeObserver:self forKeyPath:@"stillImageOutput.capturingStillImage" context:CapturingStillImageContext];
        
    });
}
- (void)viewWillAppear:(BOOL)animated {
    dispatch_async([self sessionQueue], ^{
        [self addObserver:self forKeyPath:@"sessionRunningAndDeviceAuthorized" options:(NSKeyValueObservingOptionOld | NSKeyValueObservingOptionNew) context:SessionRunningAndDeviceAuthorizedContext];
        [self addObserver:self forKeyPath:@"stillImageOutput.capturingStillImage" options:(NSKeyValueObservingOptionOld | NSKeyValueObservingOptionNew) context:CapturingStillImageContext];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(subjectAreaDidChange:) name:AVCaptureDeviceSubjectAreaDidChangeNotification object:[[self videoDeviceInput] device]];
        
        __weak CameraViewController *weakSelf = self;
        [self setRuntimeErrorHandlingObserver:[[NSNotificationCenter defaultCenter] addObserverForName:AVCaptureSessionRuntimeErrorNotification object:[self session] queue:nil usingBlock:^(NSNotification *note) {
            CameraViewController *strongSelf = weakSelf;
            dispatch_async([strongSelf sessionQueue], ^{
                // Manually restarting the session since it must have been stopped due to an error.
                [[strongSelf session] startRunning];
                
            });
        }]];
        
        NSLog(@"startRunning");
        [[self session] startRunning];
    });
}

- (void)initCam {
 }

- (BOOL)shouldAutorotate {
    return NO;
}

- (NSUInteger)supportedInterfaceOrientations
{
    return UIInterfaceOrientationMaskAll;
}

- (void)willRotateToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation duration:(NSTimeInterval)duration
{
    [[(AVCaptureVideoPreviewLayer *)[[self previewView] layer] connection] setVideoOrientation:(AVCaptureVideoOrientation)toInterfaceOrientation];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if (context == CapturingStillImageContext)
    {
        BOOL isCapturingStillImage = [change[NSKeyValueChangeNewKey] boolValue];
        
        if (isCapturingStillImage)
        {
            [self runStillImageCaptureAnimation];
        }
    }
    else if (context == SessionRunningAndDeviceAuthorizedContext)
    {
        BOOL isRunning = [change[NSKeyValueChangeNewKey] boolValue];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (isRunning)
            {
                //[[self switchCameraButton] setEnabled:YES];
                //[[self shootButton] setEnabled:YES];
            }
            else
            {
                //[[self switchCameraButton] setEnabled:NO];
                //[[self shootButton] setEnabled:NO];
            }
        });
    }
    else
    {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}


- (void)takePicture:(void(^)(UIImage*))callback {
    
    dispatch_async([self sessionQueue], ^{
        // Update the orientation on the still image output video connection before capturing.
        [[[self stillImageOutput] connectionWithMediaType:AVMediaTypeVideo] setVideoOrientation:[[(AVCaptureVideoPreviewLayer *)[[self previewView] layer] connection] videoOrientation]];
        
        // Flash set to Auto for Still Capture
        [CameraViewController setFlashMode:AVCaptureFlashModeAuto forDevice:[[self videoDeviceInput] device]];
        
        // Capture a still image.
        [[self stillImageOutput] captureStillImageAsynchronouslyFromConnection:[[self stillImageOutput] connectionWithMediaType:AVMediaTypeVideo] completionHandler:^(CMSampleBufferRef imageDataSampleBuffer, NSError *error) {
            
            if (imageDataSampleBuffer){
                
                NSData *imageData = [AVCaptureStillImageOutput jpegStillImageNSDataRepresentation:imageDataSampleBuffer];
                UIImage *image = [[UIImage alloc] initWithData:imageData];
                
                AVCaptureDevice *currentVideoDevice = [[self videoDeviceInput] device];
                
                //fix front mirroring
                if ([currentVideoDevice position] == AVCaptureDevicePositionFront) {
                     UIImage *flippedImage = [UIImage imageWithCGImage:image.CGImage scale:image.scale orientation:UIImageOrientationLeftMirrored];
                    [self.libraryImageView setImage:flippedImage];
                }
                else{
                    [self.libraryImageView setImage:image];
                }
				
				//final picture callback
                callback([self imageWithView:self.finalImageView]);
            }
        }];
    });
   
}

- focusAndExposeTap:(UIGestureRecognizer *)gestureRecognizer
{
    CGPoint devicePoint = [(AVCaptureVideoPreviewLayer *)[[self previewView] layer] captureDevicePointOfInterestForPoint:[gestureRecognizer locationInView:[gestureRecognizer view]]];
    [self focusWithMode:AVCaptureFocusModeAutoFocus exposeWithMode:AVCaptureExposureModeAutoExpose atDevicePoint:devicePoint monitorSubjectAreaChange:YES];
}

- (void)subjectAreaDidChange:(NSNotification *)notification
{
    CGPoint devicePoint = CGPointMake(.5, .5);
    [self focusWithMode:AVCaptureFocusModeContinuousAutoFocus exposeWithMode:AVCaptureExposureModeContinuousAutoExposure atDevicePoint:devicePoint monitorSubjectAreaChange:NO];
}

#pragma mark Device Configuration

- (void)focusWithMode:(AVCaptureFocusMode)focusMode exposeWithMode:(AVCaptureExposureMode)exposureMode atDevicePoint:(CGPoint)point monitorSubjectAreaChange:(BOOL)monitorSubjectAreaChange
{
    dispatch_async([self sessionQueue], ^{
        AVCaptureDevice *device = [[self videoDeviceInput] device];
        NSError *error = nil;
        if ([device lockForConfiguration:&error])
        {
            if ([device isFocusPointOfInterestSupported] && [device isFocusModeSupported:focusMode])
            {
                [device setFocusMode:focusMode];
                [device setFocusPointOfInterest:point];
            }
            if ([device isExposurePointOfInterestSupported] && [device isExposureModeSupported:exposureMode])
            {
                [device setExposureMode:exposureMode];
                [device setExposurePointOfInterest:point];
            }
            [device setSubjectAreaChangeMonitoringEnabled:monitorSubjectAreaChange];
            [device unlockForConfiguration];
        }
        else
        {
            NSLog(@"%@", error);
        }
    });
}

+ (void)setFlashMode:(AVCaptureFlashMode)flashMode forDevice:(AVCaptureDevice *)device
{
    if ([device hasFlash] && [device isFlashModeSupported:flashMode])
    {
        NSError *error = nil;
        if ([device lockForConfiguration:&error])
        {
            [device setFlashMode:flashMode];
            [device unlockForConfiguration];
        }
        else
        {
            NSLog(@"%@", error);
        }
    }
}

+ (AVCaptureDevice *)deviceWithMediaType:(NSString *)mediaType preferringPosition:(AVCaptureDevicePosition)position
{
    NSArray *devices = [AVCaptureDevice devicesWithMediaType:mediaType];
    AVCaptureDevice *captureDevice = [devices firstObject];
    
    for (AVCaptureDevice *device in devices)
    {
        if ([device position] == position)
        {
            captureDevice = device;
            break;
        }
    }
    
    return captureDevice;
}

#pragma mark UI

- (void)runStillImageCaptureAnimation
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [[[self previewView] layer] setOpacity:0.0];
        [UIView animateWithDuration:.25 animations:^{
            [[[self previewView] layer] setOpacity:1.0];
        }];
    });
}

- (void)checkDeviceAuthorizationStatus
{
    NSString *mediaType = AVMediaTypeVideo;
    
    [AVCaptureDevice requestAccessForMediaType:mediaType completionHandler:^(BOOL granted) {
        if (granted)
        {
            //Granted access to mediaType
            [self setDeviceAuthorized:YES];
        }
        else
        {
            //Not granted access to mediaType
            dispatch_async(dispatch_get_main_queue(), ^{
                [[[UIAlertView alloc] initWithTitle:@"Error"
                                            message:@"Camera permission not found. Please, check your privacy settings."
                                           delegate:self
                                  cancelButtonTitle:@"OK"
                                  otherButtonTitles:nil] show];
                [self setDeviceAuthorized:NO];
            });
        }
    }];
}

-(void) hideCamera {
    [self.view setHidden:TRUE];
}
-(void) showCamera {
    [self.view setHidden:FALSE];
}
-(void) stopCamera {
    [self dismissViewControllerAnimated:NO completion:nil];
}

-(void) switchCamera {

    //[[self switchCameraButton] setEnabled:NO];
    //[[self shootButton] setEnabled:NO];
    
    dispatch_async([self sessionQueue], ^{
        AVCaptureDevice *currentVideoDevice = [[self videoDeviceInput] device];
        AVCaptureDevicePosition preferredPosition = AVCaptureDevicePositionUnspecified;
        AVCaptureDevicePosition currentPosition = [currentVideoDevice position];
        
        switch (currentPosition)
        {
            case AVCaptureDevicePositionUnspecified:
                preferredPosition = AVCaptureDevicePositionBack;
                break;
            case AVCaptureDevicePositionBack:
                preferredPosition = AVCaptureDevicePositionFront;
                break;
            case AVCaptureDevicePositionFront:
                preferredPosition = AVCaptureDevicePositionBack;
                break;
        }
		
        if(preferredPosition == AVCaptureDevicePositionBack){
			//callback
            //[self.switchCameraButton setImage: [UIImage imageWithContentsOfFile:[self getResourcePath: @"img/icons/frames_rear_camera.png"]] forState:UIControlStateNormal];
        }
        else{
			//callback
            //[self.switchCameraButton setImage: [UIImage imageWithContentsOfFile:[self getResourcePath: @"img/icons/frames_front_camera.png"]] forState:UIControlStateNormal];
        }
		
        AVCaptureDevice *videoDevice = [CameraViewController deviceWithMediaType:AVMediaTypeVideo preferringPosition:preferredPosition];
        AVCaptureDeviceInput *videoDeviceInput = [AVCaptureDeviceInput deviceInputWithDevice:videoDevice error:nil];
        
        [[self session] beginConfiguration];
        
        [[self session] removeInput:[self videoDeviceInput]];
        if ([[self session] canAddInput:videoDeviceInput])
        {
            [[NSNotificationCenter defaultCenter] removeObserver:self name:AVCaptureDeviceSubjectAreaDidChangeNotification object:currentVideoDevice];
            
            [CameraViewController setFlashMode:AVCaptureFlashModeAuto forDevice:videoDevice];
            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(subjectAreaDidChange:) name:AVCaptureDeviceSubjectAreaDidChangeNotification object:videoDevice];
            
            [[self session] addInput:videoDeviceInput];
            [self setVideoDeviceInput:videoDeviceInput];
        }
        else {
            [[self session] addInput:[self videoDeviceInput]];
        }
        
        [[self session] commitConfiguration];
        
        //dispatch_async(dispatch_get_main_queue(), ^{
            //[[self switchCameraButton] setEnabled:YES];
            //[[self shootButton] setEnabled:YES];
        //});
    });

}


-(void) imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary *)info {
    
    // Get a reference to the captured image
    UIImage* imagePicker = [info objectForKey:UIImagePickerControllerOriginalImage];
    UIImage *image = nil;
    
    //begin - get correct image size with exact size of the preview
    CGRect screenRect = [[UIScreen mainScreen] bounds];
    
    image = [self imageWithImage:imagePicker scaledToHeight:screenRect.size.height];
    
    CGRect cropRect = CGRectMake(
                                 image.size.width/2 - screenRect.size.width/2,
                                 image.size.height/2 - screenRect.size.height/2,
                                 screenRect.size.width,
                                 screenRect.size.height
                                 );
    
    if(picker.sourceType == UIImagePickerControllerSourceTypePhotoLibrary){
        
        [self.libraryImageView setImage:image];
        [picker dismissViewControllerAnimated:true completion:nil];
    }
}

#define rad(angle) ((angle) / 180.0 * M_PI)
- (CGAffineTransform)orientationTransformedRectOfImage:(UIImage *)img {
    CGAffineTransform rectTransform;
    switch (img.imageOrientation)
    {
        case UIImageOrientationLeft:
            rectTransform = CGAffineTransformTranslate(CGAffineTransformMakeRotation(rad(90)), 0, -img.size.height);
            break;
        case UIImageOrientationRight:
            rectTransform = CGAffineTransformTranslate(CGAffineTransformMakeRotation(rad(-90)), -img.size.width, 0);
            break;
        case UIImageOrientationDown:
            rectTransform = CGAffineTransformTranslate(CGAffineTransformMakeRotation(rad(-180)), -img.size.width, -img.size.height);
            break;
        default:
            rectTransform = CGAffineTransformIdentity;
    };
    
    return CGAffineTransformScale(rectTransform, img.scale, img.scale);
}

- (UIColor *)colorFromHexString:(NSString *)hexString {
    unsigned rgbValue = 0;
    NSScanner *scanner = [NSScanner scannerWithString:hexString];
    [scanner setScanLocation:1]; // bypass '#' character
    [scanner scanHexInt:&rgbValue];
    return [UIColor colorWithRed:((rgbValue & 0xFF0000) >> 16)/255.0 green:((rgbValue & 0xFF00) >> 8)/255.0 blue:(rgbValue & 0xFF)/255.0 alpha:1.0];
}

-(UIImage *)croppedImage:(UIImage*)originalImage InRect:(CGRect)visibleRect{
    //transform visible rect to image orientation
    CGAffineTransform rectTransform = [self orientationTransformedRectOfImage:originalImage];
    visibleRect = CGRectApplyAffineTransform(visibleRect, rectTransform);
    
    //crop image
    CGImageRef imageRef = CGImageCreateWithImageInRect([originalImage CGImage], visibleRect);
    UIImage *result = [UIImage imageWithCGImage:imageRef scale:originalImage.scale orientation:originalImage.imageOrientation];
    CGImageRelease(imageRef);
    return result;
}

-(UIImage*)imageWithImage: (UIImage*) sourceImage scaledToWidth: (float) i_width {
    float oldWidth = sourceImage.size.width;
    float scaleFactor = i_width / oldWidth;
    
    float newHeight = sourceImage.size.height * scaleFactor;
    float newWidth = oldWidth * scaleFactor;
    
    UIGraphicsBeginImageContext(CGSizeMake(newWidth, newHeight));
    [sourceImage drawInRect:CGRectMake(0, 0, newWidth, newHeight)];
    UIImage *newImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return newImage;
}

-(UIImage*)imageWithImage: (UIImage*) sourceImage scaledToHeight: (float) i_height {
    float oldHeight = sourceImage.size.height;
    float scaleFactor = i_height / oldHeight;
    
    float newWidth = sourceImage.size.width * scaleFactor;
    float newHeight = oldHeight * scaleFactor;
    
    UIGraphicsBeginImageContext(CGSizeMake(newWidth, newHeight));
    [sourceImage drawInRect:CGRectMake(0, 0, newWidth, newHeight)];
    UIImage *newImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return newImage;
}

-(UIImage *)imageWithView:(UIView *)view{
    UIGraphicsBeginImageContextWithOptions(view.bounds.size, view.opaque, 0.0);
    [view.layer renderInContext:UIGraphicsGetCurrentContext()];
    UIImage * img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

-(NSString*)getResourcePath:(NSString*) path{
    NSString *imagePath = [NSString stringWithFormat:@"www/%@", path];
    NSString* pathComponents = [imagePath stringByDeletingPathExtension];
    NSString* dir = [pathComponents stringByDeletingLastPathComponent];
    NSString* fileName = [pathComponents lastPathComponent];
    NSString* extension = [imagePath pathExtension];
    NSString* bundlePath = [[NSBundle mainBundle] pathForResource:fileName ofType:extension inDirectory:dir];
    return bundlePath;
}

@end