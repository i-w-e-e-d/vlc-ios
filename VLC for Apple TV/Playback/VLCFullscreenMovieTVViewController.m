/*****************************************************************************
 * VLC for iOS
 *****************************************************************************
 * Copyright (c) 2015 VideoLAN. All rights reserved.
 * $Id$
 *
 * Authors: Felix Paul Kühne <fkuehne # videolan.org>
 *
 * Refer to the COPYING file of the official project for license.
 *****************************************************************************/

#import "VLCFullscreenMovieTVViewController.h"
#import "VLCPlaybackInfoTVViewController.h"
#import "VLCPlaybackInfoTVAnimators.h"
#import "VLCIRTVTapGestureRecognizer.h"
#import "VLCHTTPUploaderController.h"
#import "VLCSiriRemoteGestureRecognizer.h"
#import "JSAnimatedImagesView.h"
#import "MetaDataFetcherKit.h"

typedef NS_ENUM(NSInteger, VLCPlayerScanState)
{
    VLCPlayerScanStateNone,
    VLCPlayerScanStateForward2,
    VLCPlayerScanStateForward4,
};

@interface VLCFullscreenMovieTVViewController (UIViewControllerTransitioningDelegate) <UIViewControllerTransitioningDelegate, UIGestureRecognizerDelegate>
@end

@interface VLCFullscreenMovieTVViewController () <JSAnimatedImagesViewDataSource, MDFHatchetFetcherDataRecipient>

@property (nonatomic) NSTimer *hidePlaybackControlsViewAfterDeleayTimer;
@property (nonatomic) VLCPlaybackInfoTVViewController *infoViewController;
@property (nonatomic) NSNumber *scanSavedPlaybackRate;
@property (nonatomic) VLCPlayerScanState scanState;
@property (nonatomic) JSAnimatedImagesView *animatedImageView;
@property (nonatomic) MDFHatchetFetcher *audioMetaDataFetcher;
@property (nonatomic) NSString *lastArtist;
@property (nonatomic) NSMutableArray *audioImagesArray;

@end

@implementation VLCFullscreenMovieTVViewController

+ (instancetype)fullscreenMovieTVViewController
{
    return [[self alloc] initWithNibName:nil bundle:nil];
}

- (void)viewDidLoad
{
    [super viewDidLoad];

    self.extendedLayoutIncludesOpaqueBars = YES;
    self.edgesForExtendedLayout = UIRectEdgeAll;

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self
               selector:@selector(playbackDidStop:)
                   name:VLCPlaybackControllerPlaybackDidStop
                 object:nil];

    _movieView.userInteractionEnabled = NO;

    self.titleLabel.text = @"";

    self.transportBar.bufferStartFraction = 0.0;
    self.transportBar.bufferEndFraction = 1.0;
    self.transportBar.playbackFraction = 0.0;
    self.transportBar.scrubbingFraction = 0.0;

    self.dimmingView.alpha = 0.0;
    self.bottomOverlayView.alpha = 0.0;

    self.bufferingLabel.text = NSLocalizedString(@"PLEASE_WAIT", nil);


    // Panning and Swiping

    UIPanGestureRecognizer *panGestureRecognizer = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panGesture:)];
    panGestureRecognizer.delegate = self;
    [self.view addGestureRecognizer:panGestureRecognizer];

    // Button presses
    UITapGestureRecognizer *playpauseGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(playPausePressed)];
    playpauseGesture.allowedPressTypes = @[@(UIPressTypePlayPause)];
    [self.view addGestureRecognizer:playpauseGesture];

    UITapGestureRecognizer *menuTapGestureRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(menuButtonPressed:)];
    menuTapGestureRecognizer.allowedPressTypes = @[@(UIPressTypeMenu)];
    menuTapGestureRecognizer.delegate = self;
    [self.view addGestureRecognizer:menuTapGestureRecognizer];

    // IR only recognizer
    UITapGestureRecognizer *downArrowRecognizer = [[VLCIRTVTapGestureRecognizer alloc] initWithTarget:self action:@selector(showInfoVCIfNotScrubbing)];
    downArrowRecognizer.allowedPressTypes = @[@(UIPressTypeDownArrow)];
    [self.view addGestureRecognizer:downArrowRecognizer];

    UITapGestureRecognizer *leftArrowRecognizer = [[VLCIRTVTapGestureRecognizer alloc] initWithTarget:self action:@selector(handleIRPressLeft)];
    leftArrowRecognizer.allowedPressTypes = @[@(UIPressTypeLeftArrow)];
    [self.view addGestureRecognizer:leftArrowRecognizer];

    UITapGestureRecognizer *rightArrowRecognizer = [[VLCIRTVTapGestureRecognizer alloc] initWithTarget:self action:@selector(handleIRPressRight)];
    rightArrowRecognizer.allowedPressTypes = @[@(UIPressTypeRightArrow)];
    [self.view addGestureRecognizer:rightArrowRecognizer];

    // Siri remote arrow presses
    VLCSiriRemoteGestureRecognizer *siriArrowRecognizer = [[VLCSiriRemoteGestureRecognizer alloc] initWithTarget:self action:@selector(handleSiriRemote:)];
    siriArrowRecognizer.delegate = self;
    [self.view addGestureRecognizer:siriArrowRecognizer];

    JSAnimatedImagesView *animatedImageView = [[JSAnimatedImagesView alloc] initWithFrame:self.view.frame];
    animatedImageView.dataSource = self;
    animatedImageView.backgroundColor = [UIColor blackColor];
    animatedImageView.timePerImage = 20;
    self.animatedImageView = animatedImageView;
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    self.infoViewController = nil;
}

#pragma mark - view events

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];

    VLCPlaybackController *vpc = [VLCPlaybackController sharedInstance];
    vpc.delegate = self;
    [vpc recoverPlaybackState];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];

    VLCPlaybackController *vpc = [VLCPlaybackController sharedInstance];
    [vpc recoverDisplayedMetadata];
    vpc.videoOutputView = nil;
    vpc.videoOutputView = self.movieView;

    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewWillDisappear:(BOOL)animated
{
    VLCPlaybackController *vpc = [VLCPlaybackController sharedInstance];
    if (vpc.videoOutputView == self.movieView) {
        vpc.videoOutputView = nil;
    }

    [vpc stopPlayback];

    [super viewWillDisappear:animated];

    /* clean caches in case remote playback was used
     * note that if we cancel before the upload is complete
     * the cache won't be emptied, but on the next launch only (or if the system is under storage pressure)
     */
    [[VLCHTTPUploaderController sharedInstance] cleanCache];
}

- (BOOL)canBecomeFirstResponder
{
    return YES;
}

#pragma mark - UIActions
- (void)playPausePressed
{
    [self showPlaybackControlsIfNeededForUserInteraction];

    [self setScanState:VLCPlayerScanStateNone];

    VLCPlaybackController *vpc = [VLCPlaybackController sharedInstance];
    if (self.transportBar.scrubbing) {
        [self selectButtonPressed];
    } else {
        [vpc playPause];
    }
}

- (void)panGesture:(UIPanGestureRecognizer *)panGestureRecognizer
{
    switch (panGestureRecognizer.state) {
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            return;
        default:
            break;
    }

    VLCTransportBar *bar = self.transportBar;

    UIView *view = self.view;
    CGPoint translation = [panGestureRecognizer translationInView:view];

    if (!bar.scrubbing) {
        if (ABS(translation.x) > 150.0) {
            [self startScrubbing];
        } else if (translation.y > 200.0) {
            panGestureRecognizer.enabled = NO;
            panGestureRecognizer.enabled = YES;
            [self showInfoVCIfNotScrubbing];
            return;
        } else {
            return;
        }
    }

    [self showPlaybackControlsIfNeededForUserInteraction];
    [self setScanState:VLCPlayerScanStateNone];


    const CGFloat scaleFactor = 8.0;
    CGFloat fractionInView = translation.x/CGRectGetWidth(view.bounds)/scaleFactor;

    CGFloat scrubbingFraction = MAX(0.0, MIN(bar.scrubbingFraction + fractionInView,1.0));


    if (ABS(scrubbingFraction - bar.playbackFraction)<0.005) {
        scrubbingFraction = bar.playbackFraction;
    } else {
        translation.x = 0.0;
        [panGestureRecognizer setTranslation:translation inView:view];
    }

    [UIView animateWithDuration:0.3
                          delay:0.0
                        options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
                         bar.scrubbingFraction = scrubbingFraction;
                     }
                     completion:nil];
    [self updateTimeLabelsForScrubbingFraction:scrubbingFraction];
}

- (void)selectButtonPressed
{
    [self showPlaybackControlsIfNeededForUserInteraction];
    [self setScanState:VLCPlayerScanStateNone];

    VLCPlaybackController *vpc = [VLCPlaybackController sharedInstance];
    VLCTransportBar *bar = self.transportBar;
    if (bar.scrubbing) {
        bar.playbackFraction = bar.scrubbingFraction;
        [vpc.mediaPlayer setPosition:bar.scrubbingFraction];
        [self stopScrubbing];
    } else if(vpc.mediaPlayer.playing) {
        [vpc.mediaPlayer pause];
    }
}
- (void)menuButtonPressed:(UITapGestureRecognizer *)recognizer
{
    VLCTransportBar *bar = self.transportBar;
    if (bar.scrubbing) {
        [UIView animateWithDuration:0.3 animations:^{
            bar.scrubbingFraction = bar.playbackFraction;
            [bar layoutIfNeeded];
        }];
        [self updateTimeLabelsForScrubbingFraction:bar.playbackFraction];
        [self stopScrubbing];
        [self hidePlaybackControlsIfNeededAfterDelay];
    }
}

- (void)showInfoVCIfNotScrubbing
{
    if (self.transportBar.scrubbing) {
        return;
    }
    // TODO: configure with player info
    VLCPlaybackInfoTVViewController *infoViewController = self.infoViewController;
    infoViewController.transitioningDelegate = self;
    [self presentViewController:infoViewController animated:YES completion:nil];
    [self animatePlaybackControlsToVisibility:NO];
}

- (void)handleIRPressLeft
{
    [self showPlaybackControlsIfNeededForUserInteraction];
    BOOL paused = ![VLCPlaybackController sharedInstance].isPlaying;
    if (paused) {
        [self jumpBackward];
    } else
    {
        [self scanForwardPrevious];
    }
}

- (void)handleIRPressRight
{
    [self showPlaybackControlsIfNeededForUserInteraction];
    BOOL paused = ![VLCPlaybackController sharedInstance].isPlaying;
    if (paused) {
        [self jumpForward];
    } else {
        [self scanForwardNext];
    }
}

- (void)handleSiriRemote:(VLCSiriRemoteGestureRecognizer *)recognizer
{
    [self showPlaybackControlsIfNeededForUserInteraction];
    VLCTransportBarHint hint = self.transportBar.hint;
    switch (recognizer.state) {
        case UIGestureRecognizerStateBegan:
        case UIGestureRecognizerStateChanged:
            if (recognizer.isLongPress) {
                if (recognizer.touchLocation == VLCSiriRemoteTouchLocationRight) {
                    [self setScanState:VLCPlayerScanStateForward2];
                    return;
                }
            } else {
                switch (recognizer.touchLocation) {
                    case VLCSiriRemoteTouchLocationLeft:
                        hint = VLCTransportBarHintJumpBackward10;
                        break;
                    case VLCSiriRemoteTouchLocationRight:
                        hint = VLCTransportBarHintJumpForward10;
                        break;
                    default:
                        hint = VLCTransportBarHintNone;
                        break;
                }
            }
            break;
        case UIGestureRecognizerStateEnded:
            if (recognizer.isClick && !recognizer.isLongPress) {
                [self handleSiriPressUpAtLocation:recognizer.touchLocation];
            }
            [self setScanState:VLCPlayerScanStateNone];
            break;
        case UIGestureRecognizerStateCancelled:
            hint = VLCTransportBarHintNone;
            [self setScanState:VLCPlayerScanStateNone];
            break;
        default:
            break;
    }
    self.transportBar.hint = hint;
}

- (void)handleSiriPressUpAtLocation:(VLCSiriRemoteTouchLocation)location
{
    switch (location) {
        case VLCSiriRemoteTouchLocationLeft:
            [self jumpBackward];
            break;
        case VLCSiriRemoteTouchLocationRight:
            [self jumpForward];
            break;
        default:
            [self selectButtonPressed];
            break;
    }
}

#pragma mark -
static const NSInteger VLCJumpInterval = 10000; // 10 seconds
- (void)jumpForward
{
    VLCPlaybackController *vpc = [VLCPlaybackController sharedInstance];
    VLCMediaPlayer *player = vpc.mediaPlayer;

    if (player.isPlaying) {
        [player jumpForward:VLCJumpInterval];
    } else {
        [self scrubbingJumpInterval:VLCJumpInterval];
    }
}
- (void)jumpBackward
{
    VLCPlaybackController *vpc = [VLCPlaybackController sharedInstance];
    VLCMediaPlayer *player = vpc.mediaPlayer;

    if (player.isPlaying) {
        [player jumpBackward:VLCJumpInterval];
    } else {
        [self scrubbingJumpInterval:-VLCJumpInterval];
    }
}

- (void)scrubbingJumpInterval:(NSInteger)interval
{
    NSInteger duration = [VLCPlaybackController sharedInstance].mediaDuration;
    if (duration==0) {
        return;
    }
    CGFloat intervalFraction = ((CGFloat)interval)/((CGFloat)duration);
    VLCTransportBar *bar = self.transportBar;
    bar.scrubbing = YES;
    CGFloat currentFraction = bar.scrubbingFraction;
    currentFraction += intervalFraction;
    bar.scrubbingFraction = currentFraction;
    [self updateTimeLabelsForScrubbingFraction:currentFraction];
}

- (void)scanForwardNext
{
    VLCPlayerScanState nextState = self.scanState;
    switch (self.scanState) {
        case VLCPlayerScanStateNone:
            nextState = VLCPlayerScanStateForward2;
            break;
        case VLCPlayerScanStateForward2:
            nextState = VLCPlayerScanStateForward4;
            break;
        case VLCPlayerScanStateForward4:
            return;
        default:
            return;
    }
    [self setScanState:nextState];
}

- (void)scanForwardPrevious
{
    VLCPlayerScanState nextState = self.scanState;
    switch (self.scanState) {
        case VLCPlayerScanStateNone:
            return;
        case VLCPlayerScanStateForward2:
            nextState = VLCPlayerScanStateNone;
            break;
        case VLCPlayerScanStateForward4:
            nextState = VLCPlayerScanStateForward2;
            break;
        default:
            return;
    }
    [self setScanState:nextState];
}


- (void)setScanState:(VLCPlayerScanState)scanState
{
    if (_scanState == scanState) {
        return;
    }

    if (_scanState == VLCPlayerScanStateNone) {
        self.scanSavedPlaybackRate = @([VLCPlaybackController sharedInstance].playbackRate);
    }
    _scanState = scanState;
    float rate = 1.0;
    VLCTransportBarHint hint = VLCTransportBarHintNone;
    switch (scanState) {
        case VLCPlayerScanStateForward2:
            rate = 2.0;
            hint = VLCTransportBarHintScanForward;
            break;
        case VLCPlayerScanStateForward4:
            rate = 4.0;
            hint = VLCTransportBarHintScanForward;
            break;

        case VLCPlayerScanStateNone:
        default:
            rate = self.scanSavedPlaybackRate.floatValue ?: 1.0;
            hint = VLCTransportBarHintNone;
            self.scanSavedPlaybackRate = nil;
            break;
    }

    [VLCPlaybackController sharedInstance].playbackRate = rate;
    [self.transportBar setHint:hint];
}
#pragma mark -

- (void)updateTimeLabelsForScrubbingFraction:(CGFloat)scrubbingFraction
{
    VLCTransportBar *bar = self.transportBar;
    VLCPlaybackController *vpc = [VLCPlaybackController sharedInstance];
    // MAX 1, _ is ugly hack to prevent --:-- instead of 00:00
    int scrubbingTimeInt = MAX(1,vpc.mediaDuration*scrubbingFraction);
    VLCTime *scrubbingTime = [VLCTime timeWithInt:scrubbingTimeInt];
    bar.markerTimeLabel.text = [scrubbingTime stringValue];
    VLCTime *remainingTime = [VLCTime timeWithInt:-(int)(vpc.mediaDuration-scrubbingTime.intValue)];
    bar.remainingTimeLabel.text = [remainingTime stringValue];
}

- (void)startScrubbing
{
    VLCPlaybackController *vpc = [VLCPlaybackController sharedInstance];
    self.transportBar.scrubbing = YES;
    [self updateDimmingView];
    if (vpc.isPlaying) {
        [vpc playPause];
    }
}
- (void)stopScrubbing
{
    self.transportBar.scrubbing = NO;
    [self updateDimmingView];
    VLCPlaybackController *vpc = [VLCPlaybackController sharedInstance];
    [vpc.mediaPlayer play];
}

- (void)updateDimmingView
{
    BOOL shouldBeVisible = self.transportBar.scrubbing;
    BOOL isVisible = self.dimmingView.alpha == 1.0;
    if (shouldBeVisible != isVisible) {
        [UIView animateWithDuration:0.3 animations:^{
            self.dimmingView.alpha = shouldBeVisible ? 1.0 : 0.0;
        }];
    }
}

- (void)updateActivityIndicatorForState:(VLCMediaPlayerState)state {
    UIActivityIndicatorView *indicator = self.activityIndicator;
    switch (state) {
        case VLCMediaPlayerStateBuffering:
            if (!indicator.isAnimating) {
                self.activityIndicator.alpha = 1.0;
                [self.activityIndicator startAnimating];
            }
            break;
        default:
            if (indicator.isAnimating) {
                [self.activityIndicator stopAnimating];
                self.activityIndicator.alpha = 0.0;
            }
            break;
    }
}

#pragma mark - PlaybackControls

- (void)fireHidePlaybackControlsIfNotPlayingTimer:(NSTimer *)timer
{
    BOOL playing = [[VLCPlaybackController sharedInstance] isPlaying];
    if (playing) {
        [self animatePlaybackControlsToVisibility:NO];
    }
}
- (void)showPlaybackControlsIfNeededForUserInteraction
{
    if (self.bottomOverlayView.alpha == 0.0) {
        [self animatePlaybackControlsToVisibility:YES];
    }
    [self hidePlaybackControlsIfNeededAfterDelay];
}
- (void)hidePlaybackControlsIfNeededAfterDelay
{
    self.hidePlaybackControlsViewAfterDeleayTimer = [NSTimer scheduledTimerWithTimeInterval:3.0
                                                                                     target:self
                                                                                   selector:@selector(fireHidePlaybackControlsIfNotPlayingTimer:)
                                                                                   userInfo:nil repeats:NO];
}


- (void)animatePlaybackControlsToVisibility:(BOOL)visible
{
    NSTimeInterval duration = visible ? 0.3 : 1.0;

    CGFloat alpha = visible ? 1.0 : 0.0;
    [UIView animateWithDuration:duration
                     animations:^{
                         self.bottomOverlayView.alpha = alpha;
                     }];
}


#pragma mark - Properties
- (void)setHidePlaybackControlsViewAfterDeleayTimer:(NSTimer *)hidePlaybackControlsViewAfterDeleayTimer {
    [_hidePlaybackControlsViewAfterDeleayTimer invalidate];
    _hidePlaybackControlsViewAfterDeleayTimer = hidePlaybackControlsViewAfterDeleayTimer;
}

- (VLCPlaybackInfoTVViewController *)infoViewController
{
    if (!_infoViewController) {
        _infoViewController = [[VLCPlaybackInfoTVViewController alloc] initWithNibName:nil bundle:nil];
    }
    return _infoViewController;
}



#pragma mark - playback controller delegation

- (void)prepareForMediaPlayback:(VLCPlaybackController *)controller
{
    APLog(@"%s", __PRETTY_FUNCTION__);
}

- (void)playbackDidStop:(NSNotification *)aNotification
{
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)mediaPlayerStateChanged:(VLCMediaPlayerState)currentState
                      isPlaying:(BOOL)isPlaying
currentMediaHasTrackToChooseFrom:(BOOL)currentMediaHasTrackToChooseFrom
        currentMediaHasChapters:(BOOL)currentMediaHasChapters
          forPlaybackController:(VLCPlaybackController *)controller
{

    [self updateActivityIndicatorForState:currentState];

    if (controller.isPlaying) {
        [self hidePlaybackControlsIfNeededAfterDelay];
    } else {
        [self showPlaybackControlsIfNeededForUserInteraction];
    }

    if (controller.isPlaying && !self.bufferingLabel.hidden) {
        [UIView animateWithDuration:.3 animations:^{
            self.bufferingLabel.hidden = YES;
        }];
    }
}

- (void)displayMetadataForPlaybackController:(VLCPlaybackController *)controller
                                       title:(NSString *)title
                                     artwork:(UIImage *)artwork
                                      artist:(NSString *)artist
                                       album:(NSString *)album
                                   audioOnly:(BOOL)audioOnly
{
    self.titleLabel.text = title;

    JSAnimatedImagesView *animatedImageView = self.animatedImageView;
    if (audioOnly) {
        if (!self.audioImagesArray)
            self.audioImagesArray = [NSMutableArray array];

        if (!self.audioMetaDataFetcher) {
            self.audioMetaDataFetcher = [[MDFHatchetFetcher alloc] init];
            self.audioMetaDataFetcher.dataRecipient = self;
        }

        [self.audioMetaDataFetcher cancelAllRequests];

        if (artist != nil && album != nil) {
            [self.audioMetaDataFetcher searchForAlbum:album ofArtist:artist];
            APLog(@"Audio-only track meta changed, tracing artist '%@' and album '%@'", artist, album);
        } else if (artist != nil) {
            [self.audioMetaDataFetcher searchForArtist:artist];
            APLog(@"Audio-only track meta changed, tracing artist '%@'", artist);
        } else if (title != nil) {
            NSRange deviderRange = [title rangeOfString:@" - "];
            if (deviderRange.length != 0) { // for radio stations, all we have is "ARTIST - TITLE"
                title = [title substringToIndex:deviderRange.location];
            }
            APLog(@"Audio-only track meta changed, tracing artist '%@'", title);
            [self.audioMetaDataFetcher searchForArtist:title];
        }
        [self performSelectorOnMainThread:@selector(showAnimatedImagesView) withObject:nil waitUntilDone:NO];
    } else if (animatedImageView.superview != nil) {
        [self.audioMetaDataFetcher cancelAllRequests];
        [animatedImageView stopAnimating];
        [animatedImageView removeFromSuperview];
        if (self.audioImagesArray) {
            [self.audioImagesArray removeAllObjects];
        }
    }
}

#pragma mark -

- (void)playbackPositionUpdated:(VLCPlaybackController *)controller
{
    VLCMediaPlayer *mediaPlayer = controller.mediaPlayer;
    // FIXME: hard coded state since the state in mediaPlayer is incorrectly still buffering
    [self updateActivityIndicatorForState:VLCMediaPlayerStatePlaying];

    if (self.bottomOverlayView.alpha != 0.0) {
        VLCTransportBar *transportBar = self.transportBar;
        transportBar.remainingTimeLabel.text = [[mediaPlayer remainingTime] stringValue];
        transportBar.markerTimeLabel.text = [[mediaPlayer time] stringValue];
        transportBar.playbackFraction = mediaPlayer.position;
    }
}

#pragma mark - gesture recognizer delegate

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if ([gestureRecognizer.allowedPressTypes containsObject:@(UIPressTypeMenu)]) {
        return self.transportBar.scrubbing;
    }
    return YES;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer
{
    return YES;
}

#pragma mark - slide show view data source

- (NSUInteger)animatedImagesNumberOfImages:(JSAnimatedImagesView *)animatedImagesView
{
    NSUInteger retValue;
    @synchronized(self.audioImagesArray) {
        retValue = self.audioImagesArray.count;
    }
    return retValue;
}

- (UIImage *)animatedImagesView:(JSAnimatedImagesView *)animatedImagesView imageAtIndex:(NSUInteger)index
{
    UIImage *retImage;
    @synchronized(self.audioImagesArray) {
        if (index < self.audioImagesArray.count) {
            retImage = self.audioImagesArray[index];
        }
    }
    return retImage;
}

- (void)showAnimatedImagesView
{
    NSUInteger imageCount;
    JSAnimatedImagesView *animatedImageView = self.animatedImageView;
    @synchronized(self.audioImagesArray) {
        imageCount = self.audioImagesArray.count;
    }
    if (animatedImageView.superview == nil && imageCount > 1) {
        [animatedImageView reloadData];
        animatedImageView.frame = self.view.frame;
        [self.view addSubview:animatedImageView];
    } else if (imageCount > 1) {
        [animatedImageView reloadData];
        [animatedImageView startAnimating];
    }
}

#pragma mark - meta data recipient
- (void)MDFHatchetFetcher:(MDFHatchetFetcher *)aFetcher didFindAlbum:(MDFMusicAlbum *)album forArtistName:(NSString *)artistName
{
    if (![self.lastArtist isEqualToString:artistName]) {
        @synchronized(self.audioImagesArray) {
            [self.animatedImageView stopAnimating];
            [self.audioImagesArray removeAllObjects];
        }
    }
    self.lastArtist = artistName;

    NSString *artworkImageURLString = album.artworkImage;
    if (artworkImageURLString != nil)
        [self fetchAudioImage:[NSURL URLWithString:artworkImageURLString]];

    NSArray *imageURLStrings = album.largeSizedArtistImages;
    NSUInteger imageCount = imageURLStrings.count;
    NSUInteger totalImageCount;

    /* reasonably limit the number of images we fetch */
    if (imageCount > 10)
        imageCount = 10;
    totalImageCount = imageCount;
    for (NSUInteger x = 0; x < imageCount; x++)
        [self fetchAudioImage:[NSURL URLWithString:imageURLStrings[x]]];

    /* when we only have 1 HD image, duplicate it */
    if (imageCount == 1) {
        [self fetchAudioImage:[NSURL URLWithString:[imageURLStrings firstObject]]];
    }

    /* if we have too few HD pictures, try to add some medium quality ones */
    if (imageCount < 4) {
        imageURLStrings = album.mediumSizedArtistImages;
        imageCount = imageURLStrings.count;
        if (imageCount > 10)
            imageCount = 10;
        totalImageCount += imageCount;
        for (NSUInteger x = 0; x < imageCount; x++)
            [self fetchAudioImage:[NSURL URLWithString:imageURLStrings[x]]];

        /* oh crap, well better than a black screen */
        if (imageCount == 1)
            [self fetchAudioImage:[NSURL URLWithString:[imageURLStrings firstObject]]];
    }

    /* we have too few images, let's simplify our search request */
    if (totalImageCount < 4) {
        [self _simplifyMetaDataSearchString:artistName];
    }
}

- (void)MDFHatchetFetcher:(MDFHatchetFetcher *)aFetcher didFailToFindAlbum:(NSString *)albumName forArtistName:(NSString *)artistName
{
    APLog(@"%s: %@ %@", __PRETTY_FUNCTION__, artistName, albumName);
}

- (void)MDFHatchetFetcher:(MDFHatchetFetcher *)aFetcher didFindArtist:(MDFArtist *)artist forSearchRequest:(NSString *)searchRequest
{
    if (![self.lastArtist isEqualToString:searchRequest]) {
        @synchronized(self.audioImagesArray) {
            [self.animatedImageView stopAnimating];
            [self.audioImagesArray removeAllObjects];
        }
    }
    self.lastArtist = searchRequest;
    NSArray *imageURLStrings = artist.largeSizedImages;
    NSUInteger imageCount = imageURLStrings.count;
    NSUInteger totalImageCount;

    /* reasonably limit the number of images we fetch */
    if (imageCount > 10)
        imageCount = 10;
    totalImageCount = imageCount;
    for (NSUInteger x = 0; x < imageCount; x++)
        [self fetchAudioImage:[NSURL URLWithString:imageURLStrings[x]]];

    /* when we only have 1 HD image, duplicate it */
    if (imageCount == 1) {
        [self fetchAudioImage:[NSURL URLWithString:[imageURLStrings firstObject]]];
    }

    /* if we have too few HD pictures, try to add some medium quality ones */
    if (imageCount < 4) {
        imageURLStrings = artist.mediumSizedImages;
        imageCount = imageURLStrings.count;
        if (imageCount > 10)
            imageCount = 10;
        totalImageCount += imageCount;
        for (NSUInteger x = 0; x < imageCount; x++)
            [self fetchAudioImage:[NSURL URLWithString:imageURLStrings[x]]];

        /* oh crap, well better than a black screen */
        if (imageCount == 1)
            [self fetchAudioImage:[NSURL URLWithString:[imageURLStrings firstObject]]];
    }

    /* we have too few images, let's simplify our search request */
    if (totalImageCount < 4) {
        [self _simplifyMetaDataSearchString:searchRequest];
    }
}

- (void)_simplifyMetaDataSearchString:(NSString *)searchString
{
    NSRange lastRange = [searchString rangeOfString:@" " options:NSBackwardsSearch];
    if (lastRange.location != NSNotFound)
        [self.audioMetaDataFetcher searchForArtist:[searchString substringToIndex:lastRange.location]];
}

- (void)MDFHatchetFetcher:(MDFHatchetFetcher *)aFetcher didFailToFindArtistForSearchRequest:(NSString *)searchRequest
{
    APLog(@"%s: %@", __PRETTY_FUNCTION__, searchRequest);
}

- (void)fetchAudioImage:(NSURL *)url
{
    __weak typeof(self) weakSelf = self;
    NSURLSession *sharedSession = [NSURLSession sharedSession];
    NSURLSessionDataTask *task = [sharedSession dataTaskWithURL:url completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        if (!data) {
            return;
        }
        UIImage *image = [UIImage imageWithData:data];
        @synchronized(weakSelf.audioImagesArray) {
            [weakSelf.audioImagesArray addObject:image];
        }
        [weakSelf performSelectorOnMainThread:@selector(showAnimatedImagesView) withObject:nil waitUntilDone:NO];
    }];
    [task resume];
}

@end


@implementation VLCFullscreenMovieTVViewController (UIViewControllerTransitioningDelegate)

- (id<UIViewControllerAnimatedTransitioning>)animationControllerForPresentedController:(UIViewController *)presented presentingController:(UIViewController *)presenting sourceController:(UIViewController *)source
{
    return [[VLCPlaybackInfoTVTransitioningAnimator alloc] init];
}
- (id<UIViewControllerAnimatedTransitioning>)animationControllerForDismissedController:(UIViewController *)dismissed
{
    return [[VLCPlaybackInfoTVTransitioningAnimator alloc] init];
}
@end