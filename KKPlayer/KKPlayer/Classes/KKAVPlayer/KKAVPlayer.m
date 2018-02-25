//
//  KKAVPlayer.m
//  KKPlayer
//
//  Created by finger on 16/6/28.
//  Copyright © 2016年 single. All rights reserved.
//

#import "KKAVPlayer.h"
#import "KKRenderView.h"
#import <AVFoundation/AVFoundation.h>
#import "KKPlayerEventCenter.h"

static CGFloat const PixelBufferRequestInterval = 0.03f;
static NSString *const AVMediaSelectionOptionTrackIDKey = @"MediaSelectionOptionsPersistentID";

@interface KKAVPlayer()<KKRenderAVPlayerDelegate>

@property(nonatomic,weak)KKPlayerInterface *playerInterface;

@property(nonatomic,assign)KKPlayerState state;
@property(nonatomic,assign)KKPlayerState stateBeforBuffering;
@property(nonatomic,assign)NSTimeInterval playableTime;//可播放的长度
@property(atomic,assign)NSTimeInterval readyToPlayTime;
@property(nonatomic,assign)BOOL seeking;
@property(atomic,assign)BOOL playing;
@property(atomic,assign)BOOL buffering;
@property(atomic,assign)BOOL hasPixelBuffer;

//播放器相关
@property(atomic,strong)id playBackTimeObserver;//监听播放进度
@property(nonatomic,strong)AVPlayer *player;//渲染图层
@property(nonatomic,strong)AVPlayerItem *playerItem;//播放对象
@property(atomic,strong)AVURLAsset *asset;//播放资源
@property(atomic,strong)AVPlayerItemVideoOutput *output;//获取视频帧的数据
@property(nonatomic,strong)NSArray<NSString *> *assetloadKeys;

//音视频轨道信息
@property(nonatomic,assign)BOOL videoEnable;
@property(nonatomic,assign)BOOL audioEnable;
@property(nonatomic,strong)KKPlayerTrack *videoTrack;
@property(nonatomic,strong)KKPlayerTrack *audioTrack;
@property(nonatomic,strong)NSArray<KKPlayerTrack *> *videoTracks;
@property(nonatomic,strong)NSArray<KKPlayerTrack *> *audioTracks;

@end

@implementation KKAVPlayer

+ (instancetype)playerWithPlayerInterface:(KKPlayerInterface *)playerInterface{
    return [[self alloc] initWithPlayerInterface:playerInterface];
}

- (instancetype)initWithPlayerInterface:(KKPlayerInterface *)playerInterface{
    if (self = [super init]) {
        self.playerInterface = playerInterface;
        self.assetloadKeys = @[@"tracks", @"playable"] ;
    }
    return self;
}

- (void)dealloc{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self clear];
}

#pragma mark -- 准备操作

- (void)prepareVideo{
    
    [self clear];
    
    if (!self.playerInterface.contentURL){
        return;
    }
    
    [((KKRenderView *)(self.playerInterface.videoRenderView)) setRenderAVPlayerDelegate:self];
    [((KKRenderView *)(self.playerInterface.videoRenderView)) setDecodeType:KKDecoderTypeAVPlayer];
    
    [self startBuffering];
    
    self.asset = [AVURLAsset assetWithURL:self.playerInterface.contentURL];
    
    switch (self.playerInterface.videoType) {
        case KKVideoTypeNormal:
            [self setupPlayerItemAutoLoadedAsset:YES];
            [self setupPlayerWithPlayItem:self.playerItem];
            [((KKRenderView *)(self.playerInterface.videoRenderView)) setRendererType:KKRendererTypeAVPlayerLayer];
            break;
        case KKVideoTypeVR:{//VR使用opengl渲染,视频帧数据从AVPlayerItemVideoOutput中获取
            [self setupPlayerItemAutoLoadedAsset:NO];
            [self setupPlayerWithPlayItem:self.playerItem];
            [((KKRenderView *)(self.playerInterface.videoRenderView)) setRendererType:KKRendererTypeOpenGL];
            
            @weakify(self);
            [self.asset loadValuesAsynchronouslyForKeys:self.assetloadKeys completionHandler:^{
                @strongify(self);
                dispatch_async(dispatch_get_main_queue(), ^{
                    for (NSString * loadKey in self.assetloadKeys) {
                        NSError * error = nil;
                        AVKeyValueStatus keyStatus = [self.asset statusOfValueForKey:loadKey error:&error];
                        if (keyStatus == AVKeyValueStatusFailed) {
                            KKPlayerLog(@"AVAsset load failed");
                            return;
                        }
                    }
                    NSError *error = nil;
                    AVKeyValueStatus trackStatus = [self.asset statusOfValueForKey:@"tracks" error:&error];
                    if (trackStatus == AVKeyValueStatusLoaded) {
                        [self setupFrameOutput];
                    } else {
                        KKPlayerLog(@"AVAsset load failed");
                    }
                });
            }];
        }
            break;
    }
}

#pragma mark -- 初始化AVPlayerItem

- (void)setupPlayerItemAutoLoadedAsset:(BOOL)autoLoadedAsset{
    if(autoLoadedAsset){
        self.playerItem = [AVPlayerItem playerItemWithAsset:self.asset automaticallyLoadedAssetKeys:self.assetloadKeys];
    }else{
        self.playerItem = [AVPlayerItem playerItemWithAsset:self.asset];
    }
    [self.playerItem addObserver:self forKeyPath:@"status" options:0 context:NULL];//播放状态
    [self.playerItem addObserver:self forKeyPath:@"playbackBufferEmpty" options:NSKeyValueObservingOptionNew context:NULL];//缓冲状态
    [self.playerItem addObserver:self forKeyPath:@"loadedTimeRanges" options:NSKeyValueObservingOptionNew context:NULL];//加载情况
    
    //播放完成通知
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playerItemPlayEnd:) name:AVPlayerItemDidPlayToEndTimeNotification object:self.playerItem];
    //播放错误通知
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playerItemFail:) name:AVPlayerItemFailedToPlayToEndTimeNotification object:self.playerItem];
}

#pragma mark -- 初始化渲染图层

- (void)setupPlayerWithPlayItem:(AVPlayerItem *)playItem{
    
    self.player = [AVPlayer playerWithPlayerItem:playItem];
    
    @weakify(self);
    self.playBackTimeObserver = [self.player addPeriodicTimeObserverForInterval:CMTimeMake(1, 1) queue:dispatch_get_main_queue() usingBlock:^(CMTime time) {
        @strongify(self);
        if (self.state == KKPlayerStatePlaying) {
            CGFloat current = CMTimeGetSeconds(time);
            CGFloat duration = self.duration;
            double percent = [self percentForTime:current duration:duration];
            if(self.playerInterface.progressChangeBlock){
                self.playerInterface.progressChangeBlock(self.playerInterface, percent, current, duration);
            }
            if(self.playerInterface.playerStateDelegate){
                [self.playerInterface.playerStateDelegate progressChange:self.playerInterface percent:percent currentTime:current totalTime:duration];
            }
        }
    }];
    
    [((KKRenderView *)(self.playerInterface.videoRenderView)) resetAVPlayer];
    
    [self reloadVolume];
}

#pragma mark -- 播放控制

- (void)play{
    
    self.playing = YES;
    
    switch (self.state) {
        case KKPlayerStateFinished:
            [self.player seekToTime:kCMTimeZero];
            self.state = KKPlayerStatePlaying;
            break;
        case KKPlayerStateFailed:
            [self clear];
            [self prepareVideo];
            break;
        case KKPlayerStateNone:
            self.state = KKPlayerStateBuffering;
            break;
        case KKPlayerStateSuspend:
            if (self.buffering) {
                self.state = KKPlayerStateBuffering;
            } else {
                self.state = KKPlayerStatePlaying;
            }
            break;
        case KKPlayerStateReadyToPlay:
            self.state = KKPlayerStatePlaying;
            break;
        default:
            break;
    }
    
    [self.player play];
}

- (void)startBuffering{
    if (self.playing) {
        [self.player pause];
    }
    self.buffering = YES;
    if (self.state != KKPlayerStateBuffering) {
        self.stateBeforBuffering = self.state;
    }
    self.state = KKPlayerStateBuffering;
}

- (void)stopBuffering{
    self.buffering = NO;
}

- (void)resumeStateAfterBuffering{
    if (self.playing) {
        [self.player play];
        self.state = KKPlayerStatePlaying;
    } else if (self.state == KKPlayerStateBuffering) {
        self.state = self.stateBeforBuffering;
    }
}

- (void)pause{
    [self.player pause];
    self.playing = NO;
    self.state = KKPlayerStateSuspend;
}

- (BOOL)seekEnable{
    if (self.duration <= 0 || self.playerItem.status != AVPlayerItemStatusReadyToPlay) {
        return NO;
    }
    return YES;
}

- (void)seekToTime:(NSTimeInterval)time{
    [self seekToTime:time completeHandler:nil];
}

- (void)seekToTime:(NSTimeInterval)time completeHandler:(void (^)(BOOL))completeHandler{
    if (!self.seekEnable || self.playerItem.status != AVPlayerItemStatusReadyToPlay) {
        if (completeHandler) {
            completeHandler(NO);
        }
        return;
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        self.seeking = YES;
        [self startBuffering];
        
        @weakify(self);
        [self.playerItem seekToTime:CMTimeMakeWithSeconds(time, NSEC_PER_SEC) completionHandler:^(BOOL finished) {
            dispatch_async(dispatch_get_main_queue(), ^{
                @strongify(self);
                self.seeking = NO;
                [self stopBuffering];
                [self resumeStateAfterBuffering];
                if (completeHandler) {
                    completeHandler(finished);
                }
                KKPlayerLog(@"KKAVPlayer seek success");
            });
        }];
    });
}

- (void)stop{
    [self clear];
}

#pragma mark - Setter/Getter

- (NSTimeInterval)progress{
    CMTime currentTime = self.playerItem.currentTime;
    Boolean indefinite = CMTIME_IS_INDEFINITE(currentTime);
    Boolean invalid = CMTIME_IS_INVALID(currentTime);
    if (indefinite || invalid) {
        return 0;
    }
    return CMTimeGetSeconds(self.playerItem.currentTime);
}

- (NSTimeInterval)duration{
    CMTime duration = self.playerItem.duration;
    Boolean indefinite = CMTIME_IS_INDEFINITE(duration);
    Boolean invalid = CMTIME_IS_INVALID(duration);
    if (indefinite || invalid) {
        return 0;
    }
    return CMTimeGetSeconds(self.playerItem.duration);;
}

- (double)percentForTime:(NSTimeInterval)time duration:(NSTimeInterval)duration{
    double percent = 0;
    if (time > 0) {
        if (duration <= 0) {
            percent = 1;
        } else {
            percent = time / duration;
        }
    }
    return percent;
}

- (NSTimeInterval)bitrate{
    return 0;
}

- (void)setState:(KKPlayerState)state{
    if (_state != state) {
        KKPlayerState temp = _state;
        _state = state;
        switch (self.state) {
            case KKPlayerStateFinished:
                self.playing = NO;
                break;
            case KKPlayerStateFailed:
                self.playing = NO;
                break;
            default:
                break;
        }
        [KKPlayerEventCenter raiseEvent:self.playerInterface statePrevious:temp current:_state];
    }
}

- (void)reloadVolume{
    self.player.volume = self.playerInterface.volume;
}

- (void)reloadPlayableTime{
    if (self.playerItem.status == AVPlayerItemStatusReadyToPlay) {
        CMTimeRange range = [self.playerItem.loadedTimeRanges.firstObject CMTimeRangeValue];
        if (CMTIMERANGE_IS_VALID(range)) {
            NSTimeInterval start = CMTimeGetSeconds(range.start);
            NSTimeInterval duration = CMTimeGetSeconds(range.duration);
            self.playableTime = (start + duration);
        }
    } else {
        self.playableTime = 0;
    }
}

- (void)setPlayableTime:(NSTimeInterval)playableTime{
    if (_playableTime != playableTime) {
        _playableTime = playableTime;
        CGFloat duration = self.duration;
        double percent = [self percentForTime:_playableTime duration:duration];
        [KKPlayerEventCenter raiseEvent:self.playerInterface playablePercent:percent current:playableTime total:duration];
    }
}

- (CGSize)presentationSize{
    if (self.playerItem) {
        return self.playerItem.presentationSize;
    }
    return CGSizeZero;
}


#pragma mark -- KKRenderAVPlayerDelegate

- (AVPlayer *)renderGetAVPlayer{
    return self.player;
}

- (CVPixelBufferRef)renderGetPixelBufferAtCurrentTime{
    if (self.seeking) return nil;
    
    BOOL hasNewPixelBuffer = [self.output hasNewPixelBufferForItemTime:self.playerItem.currentTime];
    if (!hasNewPixelBuffer) {
        if (self.hasPixelBuffer){
            return nil;
        }
        [self trySetupFrameOutput];
        return nil;
    }
    
    CVPixelBufferRef pixelBuffer = [self.output copyPixelBufferForItemTime:self.playerItem.currentTime itemTimeForDisplay:nil];
    if (!pixelBuffer) {
        [self trySetupFrameOutput];
    } else {
        self.hasPixelBuffer = YES;
    }
    return pixelBuffer;
}

- (UIImage *)renderGetSnapshotAtCurrentTime{
    switch (self.playerInterface.videoType) {
        case KKVideoTypeNormal:{
            AVAssetImageGenerator *imageGenerator = [AVAssetImageGenerator assetImageGeneratorWithAsset:self.asset];
            imageGenerator.appliesPreferredTrackTransform = YES;
            imageGenerator.requestedTimeToleranceBefore = kCMTimeZero;
            imageGenerator.requestedTimeToleranceAfter = kCMTimeZero;
            
            NSError * error = nil;
            CMTime time = self.playerItem.currentTime;
            CMTime actualTime;
            CGImageRef cgImage = [imageGenerator copyCGImageAtTime:time actualTime:&actualTime error:&error];
            UIImage * image = KKImageWithCGImage(cgImage);
            return image;
        }
            break;
        case KKVideoTypeVR:{
            return nil;
        }
            break;
    }
}

#pragma mark -- KVO,播放状态

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSString *,id> *)change context:(void *)context{
    if (object == self.playerItem) {
        if ([keyPath isEqualToString:@"status"]){
            switch (self.playerItem.status) {
                case AVPlayerItemStatusUnknown:{
                    [self startBuffering];
                    KKPlayerLog(@"KKAVPlayer item status unknown");
                }
                    break;
                case AVPlayerItemStatusReadyToPlay:{
                    [self stopBuffering];
                    [self setupTrackInfo];
                    KKPlayerLog(@"KKAVPlayer item status ready to play");
                    self.readyToPlayTime = [NSDate date].timeIntervalSince1970;
                    self.state = KKPlayerStateReadyToPlay;
                }
                    break;
                case AVPlayerItemStatusFailed:{
                    KKPlayerLog(@"KKAVPlayer item status failed");
                    
                    [self stopBuffering];
                    
                    self.readyToPlayTime = 0;
                    
                    NSError *error = nil;
                    if (self.playerItem.error) {
                        error = self.playerItem.error;
                    } else if (self.player.error) {
                        error = self.player.error;
                    } else {
                        error = [NSError errorWithDomain:@"AVPlayer playback error" code:-1 userInfo:nil];
                    }
                    self.state = KKPlayerStateFailed;
                    [KKPlayerEventCenter raiseEvent:self.playerInterface error:error];
                }
                    break;
            }
        }else if ([keyPath isEqualToString:@"playbackBufferEmpty"]){
            if (self.playerItem.playbackBufferEmpty) {
                [self startBuffering];
            }
        }else if ([keyPath isEqualToString:@"loadedTimeRanges"]){
            [self reloadPlayableTime];
            NSTimeInterval interval = self.playableTime - self.progress;//剩余的缓冲时长
            NSTimeInterval residue = self.duration - self.progress;//剩余的播放时间
            if (interval > self.playerInterface.playableBufferInterval) {
                [self stopBuffering];
                [self resumeStateAfterBuffering];
            } else if (interval < 0.3 && residue > 1.5) {
                [self startBuffering];
            }
        }
    }
}

#pragma mark -- 播放完成/播放错误通知

- (void)playerItemPlayEnd:(NSNotification *)notification{
    self.state = KKPlayerStateFinished;
}

- (void)playerItemFail:(NSNotification *)notification{
    self.state = KKPlayerStateFailed ;
}

#pragma mark -- 设置视频帧的输出

- (void)trySetupFrameOutput{
    BOOL isReadyToPlay = self.playerItem.status == AVPlayerStatusReadyToPlay && self.readyToPlayTime > 0 && (([NSDate date].timeIntervalSince1970 - self.readyToPlayTime) > 0.3);
    if (isReadyToPlay) {
        [self setupFrameOutput];
    }
}

- (void)setupFrameOutput{
    [self cleanFrameOutput];
    NSDictionary *pixelBufferAttr = @{(id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)};
    self.output = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:pixelBufferAttr];
    [self.output requestNotificationOfMediaDataChangeWithAdvanceInterval:PixelBufferRequestInterval];
    [self.playerItem addOutput:self.output];
    
    KKPlayerLog(@"KKAVPlayer add output success");
}

#pragma mark -- 清理工作

- (void)clear{
    [KKPlayerEventCenter raiseEvent:self.playerInterface progressPercent:0 current:0 total:0];
    [KKPlayerEventCenter raiseEvent:self.playerInterface playablePercent:0 current:0 total:0];
    
    [self.asset cancelLoading];
    self.asset = nil;
    
    [self cleanFrameOutput];
    [self cleanAVPlayerItem];
    [self cleanAVPlayer];
    [self cleanTrackInfo];
    
    self.state = KKPlayerStateNone;
    self.stateBeforBuffering = KKPlayerStateNone;
    self.seeking = NO;
    self.playableTime = 0;
    self.readyToPlayTime = 0;
    self.buffering = NO;
    self.playing = NO;
    ((KKRenderView *)(self.playerInterface.videoRenderView)).decodeType = KKDecoderTypeEmpty;
    ((KKRenderView *)(self.playerInterface.videoRenderView)).rendererType = KKRendererTypeEmpty;
}

- (void)cleanFrameOutput{
    if (self.playerItem) {
        [self.playerItem removeOutput:self.output];
    }
    self.output = nil;
    self.hasPixelBuffer = NO;
}

- (void)cleanAVPlayerItem{
    if (self.playerItem) {
        [self.playerItem cancelPendingSeeks];
        [self.playerItem removeObserver:self forKeyPath:@"status"];
        [self.playerItem removeObserver:self forKeyPath:@"playbackBufferEmpty"];
        [self.playerItem removeObserver:self forKeyPath:@"loadedTimeRanges"];
        [self.playerItem removeOutput:self.output];
        [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:self.playerItem];
        self.playerItem = nil;
    }
}

- (void)cleanAVPlayer{
    [self.player pause];
    [self.player cancelPendingPrerolls];
    [self.player replaceCurrentItemWithPlayerItem:nil];
    
    if (self.playBackTimeObserver) {
        [self.player removeTimeObserver:self.playBackTimeObserver];
        self.playBackTimeObserver = nil;
    }
    
    self.player = nil;
    
    [((KKRenderView *)(self.playerInterface.videoRenderView)) resetAVPlayer];
}

- (void)cleanTrackInfo{
    self.videoEnable = NO;
    self.videoTrack = nil;
    self.videoTracks = nil;
    
    self.audioEnable = NO;
    self.audioTrack = nil;
    self.audioTracks = nil;
}

#pragma mark -- track info

- (void)setupTrackInfo{
    if (self.videoEnable || self.audioEnable){
        return;
    }
    
    NSMutableArray <KKPlayerTrack *> *videoTracks = [NSMutableArray array];
    NSMutableArray <KKPlayerTrack *> *audioTracks = [NSMutableArray array];
    
    for (AVAssetTrack *obj in self.asset.tracks) {
        if ([obj.mediaType isEqualToString:AVMediaTypeVideo]) {
            self.videoEnable = YES;
            [videoTracks addObject:[self playerTrackFromAVTrack:obj]];
        } else if ([obj.mediaType isEqualToString:AVMediaTypeAudio]) {
            self.audioEnable = YES;
            [audioTracks addObject:[self playerTrackFromAVTrack:obj]];
        }
    }
    
    if (videoTracks.count > 0) {
        self.videoTracks = videoTracks;
        AVMediaSelectionGroup *videoGroup = [self.asset mediaSelectionGroupForMediaCharacteristic:AVMediaCharacteristicVisual];
        if (videoGroup) {
            int trackID = [[videoGroup.defaultOption.propertyList objectForKey:AVMediaSelectionOptionTrackIDKey] intValue];
            for (KKPlayerTrack *obj in self.videoTracks) {
                if (obj.index == (int)trackID) {
                    self.videoTrack = obj;
                }
            }
            if (!self.videoTrack) {
                self.videoTrack = self.videoTracks.firstObject;
            }
        } else {
            self.videoTrack = self.videoTracks.firstObject;
        }
    }
    if (audioTracks.count > 0) {
        self.audioTracks = audioTracks;
        AVMediaSelectionGroup *audioGroup = [self.asset mediaSelectionGroupForMediaCharacteristic:AVMediaCharacteristicAudible];
        if (audioGroup) {
            int trackID = [[audioGroup.defaultOption.propertyList objectForKey:AVMediaSelectionOptionTrackIDKey] intValue];
            for (KKPlayerTrack *obj in self.audioTracks) {
                if (obj.index == (int)trackID) {
                    self.audioTrack = obj;
                }
            }
            if (!self.audioTrack) {
                self.audioTrack = self.audioTracks.firstObject;
            }
        } else {
            self.audioTrack = self.audioTracks.firstObject;
        }
    }
}

- (KKPlayerTrack *)playerTrackFromAVTrack:(AVAssetTrack *)track{
    if (track) {
        KKPlayerTrack *obj = [[KKPlayerTrack alloc] init];
        obj.index = (int)track.trackID;
        obj.name = track.languageCode;
        return obj;
    }
    return nil;
}

@end
