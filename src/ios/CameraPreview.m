#import <Cordova/CDV.h>
#import <Cordova/CDVPlugin.h>
#import <Cordova/CDVInvokedUrlCommand.h>
#import <GLKit/GLKit.h>
#import "CameraPreview.h"

#define TMP_IMAGE_PREFIX @"cpcp_capture_"

typedef NS_ENUM(NSInteger, CPCameraGridStyle) {
  CPCameraGridStyleNone = 0,
  CPCameraGridStyleThirds = 1,
  CPCameraGridStyleRice = 2
};

@interface CPCameraGridOverlayView : UIView
@property (nonatomic, assign) CPCameraGridStyle gridStyle;
@end

@implementation CPCameraGridOverlayView

- (instancetype)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    self.backgroundColor = [UIColor clearColor];
    self.userInteractionEnabled = NO;
    self.gridStyle = CPCameraGridStyleNone;
  }
  return self;
}

- (void)setGridStyle:(CPCameraGridStyle)gridStyle {
  _gridStyle = gridStyle;
  [self setNeedsDisplay];
}

- (void)drawLineFrom:(CGPoint)fromPoint to:(CGPoint)toPoint {
  UIBezierPath *path = [UIBezierPath bezierPath];
  [path moveToPoint:fromPoint];
  [path addLineToPoint:toPoint];
  path.lineWidth = 1.0;
  [path stroke];
}

- (void)drawRect:(CGRect)rect {
  if (self.gridStyle == CPCameraGridStyleNone || rect.size.width <= 0 || rect.size.height <= 0) {
    return;
  }

  [[UIColor colorWithWhite:1.0 alpha:0.45] setStroke];

  CGFloat oneThirdW = rect.size.width / 3.0;
  CGFloat twoThirdW = oneThirdW * 2.0;
  CGFloat oneThirdH = rect.size.height / 3.0;
  CGFloat twoThirdH = oneThirdH * 2.0;

  [self drawLineFrom:CGPointMake(oneThirdW, 0.0) to:CGPointMake(oneThirdW, rect.size.height)];
  [self drawLineFrom:CGPointMake(twoThirdW, 0.0) to:CGPointMake(twoThirdW, rect.size.height)];
  [self drawLineFrom:CGPointMake(0.0, oneThirdH) to:CGPointMake(rect.size.width, oneThirdH)];
  [self drawLineFrom:CGPointMake(0.0, twoThirdH) to:CGPointMake(rect.size.width, twoThirdH)];

  if (self.gridStyle == CPCameraGridStyleRice) {
    [self drawLineFrom:CGPointMake(0.0, 0.0) to:CGPointMake(rect.size.width, rect.size.height)];
    [self drawLineFrom:CGPointMake(rect.size.width, 0.0) to:CGPointMake(0.0, rect.size.height)];
  }
}

@end

@interface CameraPreview ()

@property (nonatomic, strong) UIButton *settingsButton;
@property (nonatomic, strong) CPCameraGridOverlayView *gridOverlayView;
@property (nonatomic, assign) CGRect previewContainerFrame;
@property (nonatomic, assign) CGFloat desiredCaptureRatio;
@property (nonatomic, assign) NSTimeInterval captureTimerSeconds;
@property (nonatomic, strong) UIView *settingsDimView;
@property (nonatomic, strong) UIView *settingsCardView;
@property (nonatomic, strong) UIView *previewBackgroundView;
@property (nonatomic, assign) BOOL pendingResumeWhenActive;

@end

@implementation CameraPreview

-(void) pluginInitialize{
  // start as transparent
  self.webView.opaque = NO;
  self.webView.backgroundColor = [UIColor clearColor];
  self.pendingResumeWhenActive = NO;

  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(onApplicationDidBecomeActive:)
                                               name:UIApplicationDidBecomeActiveNotification
                                             object:nil];
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (BOOL)isApplicationActive {
  if (@available(iOS 13.0, *)) {
    NSSet<UIScene *> *connectedScenes = [UIApplication sharedApplication].connectedScenes;
    for (UIScene *scene in connectedScenes) {
      if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState == UISceneActivationStateForegroundActive) {
        return YES;
      }
    }
    return NO;
  }

  return [UIApplication sharedApplication].applicationState == UIApplicationStateActive;
}

- (void)startCaptureSessionIfAllowed:(NSString *)source {
  if (self.sessionManager == nil || self.sessionManager.session == nil) {
    NSLog(@"[CameraPreview][%@] skip start: session is nil", source);
    return;
  }

  if (![self isApplicationActive]) {
    self.pendingResumeWhenActive = YES;
    NSLog(@"[CameraPreview][%@] defer start: app/scene is not foreground active", source);
    return;
  }

  self.pendingResumeWhenActive = NO;
  dispatch_async(self.sessionManager.sessionQueue, ^{
    if (!self.sessionManager.session.isRunning) {
      NSLog(@"[CameraPreview][%@] startRunning", source);
      [self.sessionManager.session startRunning];
    } else {
      NSLog(@"[CameraPreview][%@] start skipped: already running", source);
    }
  });
}

- (void)stopCaptureSession:(NSString *)source {
  if (self.sessionManager == nil || self.sessionManager.session == nil) {
    NSLog(@"[CameraPreview][%@] skip stop: session is nil", source);
    return;
  }

  dispatch_async(self.sessionManager.sessionQueue, ^{
    if (self.sessionManager.session.isRunning) {
      NSLog(@"[CameraPreview][%@] stopRunning", source);
      [self.sessionManager.session stopRunning];
    } else {
      NSLog(@"[CameraPreview][%@] stop skipped: already stopped", source);
    }
  });
}

- (void)onApplicationDidBecomeActive:(NSNotification *)notification {
  if (!self.pendingResumeWhenActive) {
    return;
  }

  if (self.cameraRenderController == nil || self.cameraRenderController.view.hidden) {
    NSLog(@"[CameraPreview][didBecomeActive] pending resume canceled: camera hidden or not ready");
    self.pendingResumeWhenActive = NO;
    return;
  }

  [self startCaptureSessionIfAllowed:@"didBecomeActive"];
}

- (void) startCamera:(CDVInvokedUrlCommand*)command {

  CDVPluginResult *pluginResult;

  if (self.sessionManager != nil) {
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Camera already started!"];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
    return;
  }

  if (command.arguments.count > 3) {
    CGFloat x = (CGFloat)[command.arguments[0] floatValue] + self.webView.frame.origin.x;
    CGFloat y = (CGFloat)[command.arguments[1] floatValue] + self.webView.frame.origin.y;
    CGFloat width = (CGFloat)[command.arguments[2] floatValue];
    CGFloat height = (CGFloat)[command.arguments[3] floatValue];
    NSString *defaultCamera = command.arguments[4];
    BOOL tapToTakePicture = (BOOL)[command.arguments[5] boolValue];
    BOOL dragEnabled = (BOOL)[command.arguments[6] boolValue];
    BOOL toBack = (BOOL)[command.arguments[7] boolValue];
    CGFloat alpha = (CGFloat)[command.arguments[8] floatValue];
    NSString *backgroundColor = command.arguments.count > 9 ? command.arguments[9] : nil;
    BOOL tapToFocus = (BOOL) [command.arguments[10] boolValue];
    BOOL disableExifHeaderStripping = (BOOL) [command.arguments[11] boolValue]; // ignore Android only
    self.shouldStoreToFile = (BOOL) [command.arguments[12] boolValue];
    BOOL enableAutoSettings = command.arguments.count > 13 ? (BOOL) [command.arguments[13] boolValue] : NO;

    // Create the session manager
    self.sessionManager = [[CameraSessionManager alloc] init];

    // render controller setup
    self.cameraRenderController = [[CameraRenderController alloc] init];
    self.cameraRenderController.dragEnabled = dragEnabled;
    self.cameraRenderController.tapToTakePicture = tapToTakePicture;
    self.cameraRenderController.tapToFocus = tapToFocus;
    self.cameraRenderController.sessionManager = self.sessionManager;
    self.cameraRenderController.view.frame = CGRectMake(x, y, width, height);
    self.previewContainerFrame = self.cameraRenderController.view.frame;
    self.desiredCaptureRatio = 0.0;
    self.captureTimerSeconds = 0.0;
    self.cameraRenderController.delegate = self;

    // apply background color to camera view. Accepts hex strings like #RRGGBB or #AARRGGBB or the string "transparent"
    UIColor *bgColorUIColor = [UIColor blackColor];
    if ([backgroundColor isKindOfClass:[NSString class]] && ((NSString*)backgroundColor).length > 0) {
      NSString *bg = (NSString*)backgroundColor;
      if ([[bg lowercaseString] isEqualToString:@"transparent"]) {
        bgColorUIColor = [UIColor clearColor];
      } else {
        NSString *c = bg;
        if ([c hasPrefix:@"#"]) {
          c = [c substringFromIndex:1];
        }
        unsigned int hex = 0;
        NSScanner *scanner = [NSScanner scannerWithString:c];
        [scanner scanHexInt:&hex];
        if (c.length == 6) {
          bgColorUIColor = [self colorWithHex:hex alpha:1.0];
        } else if (c.length == 8) {
          CGFloat a = ((hex >> 24) & 0xFF) / 255.0;
          NSInteger rgb = hex & 0xFFFFFF;
          bgColorUIColor = [self colorWithHex:rgb alpha:a];
        } else {
          bgColorUIColor = [self colorWithHex:hex alpha:1.0];
        }
      }
    }
    self.cameraRenderController.view.backgroundColor = bgColorUIColor;

    [self.viewController addChildViewController:self.cameraRenderController];

    // ensure we have a full-screen background view to show color behind/around the preview
    if (!self.previewBackgroundView) {
      self.previewBackgroundView = [[UIView alloc] initWithFrame:self.viewController.view.bounds];
      self.previewBackgroundView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    }
    self.previewBackgroundView.backgroundColor = bgColorUIColor;

    if (toBack) {
      // display the camera below the webview

      // make transparent
      self.webView.opaque = NO;
      self.webView.backgroundColor = [UIColor clearColor];

      self.webView.scrollView.opaque = NO;
      self.webView.scrollView.backgroundColor = [UIColor clearColor];

      if (![self.previewBackgroundView isDescendantOfView:self.viewController.view]) {
        [self.viewController.view insertSubview:self.previewBackgroundView atIndex:0];
      }
      [self.previewBackgroundView addSubview:self.cameraRenderController.view];
      [self.webView.superview bringSubviewToFront:self.webView];
    } else {
      // camera in front
      if (![self.previewBackgroundView isDescendantOfView:self.viewController.view]) {
        [self.viewController.view insertSubview:self.previewBackgroundView aboveSubview:self.webView];
      }
      self.cameraRenderController.view.alpha = alpha;
      [self.viewController.view insertSubview:self.cameraRenderController.view aboveSubview:self.previewBackgroundView];
    }

    [self setupIOSSettingsButtonIfNeeded:enableAutoSettings];

    // Setup session
    self.sessionManager.delegate = self.cameraRenderController;

    [self.sessionManager setupSession:defaultCamera completion:^(BOOL started) {

      if (started && enableAutoSettings) {
        [self.sessionManager setFocusMode:@"continuous"];
        [self.sessionManager setExposureMode:@"continuous"];
        [self.sessionManager setWhiteBalanceMode:@"continuous"];
        [self.sessionManager setFlashMode:AVCaptureFlashModeAuto];
      }

      [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];

    }];

  } else {
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Invalid number of parameters"];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
  }
}

- (void) setupIOSSettingsButtonIfNeeded:(BOOL)enabled {
  if (!enabled || self.cameraRenderController == nil) {
    return;
  }

  if (self.settingsButton != nil) {
    [self.settingsButton removeFromSuperview];
    self.settingsButton = nil;
  }

  CGFloat topInset = 0.0;
  if (@available(iOS 11.0, *)) {
    topInset = self.cameraRenderController.view.safeAreaInsets.top;
  }

  UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
  button.frame = CGRectMake(self.cameraRenderController.view.bounds.size.width - 52.0, 12.0 + topInset + 8.0, 40.0, 40.0);
  button.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
  button.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.4];
  button.tintColor = [UIColor whiteColor];
  button.layer.cornerRadius = 20.0;
  button.clipsToBounds = YES;

  if (@available(iOS 13.0, *)) {
    UIImage *gearImage = [UIImage systemImageNamed:@"gearshape.fill"];
    [button setImage:gearImage forState:UIControlStateNormal];
  } else {
    [button setTitle:@"SET" forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
  }

  [button addTarget:self action:@selector(onSettingsButtonTapped) forControlEvents:UIControlEventTouchUpInside];
  [self.cameraRenderController.view addSubview:button];
  self.settingsButton = button;

  if (self.gridOverlayView == nil) {
    CPCameraGridOverlayView *overlay = [[CPCameraGridOverlayView alloc] initWithFrame:self.cameraRenderController.view.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.gridStyle = CPCameraGridStyleNone;
    [self.cameraRenderController.view addSubview:overlay];
    [self.cameraRenderController.view bringSubviewToFront:button];
    self.gridOverlayView = overlay;
  }
}

- (void) onSettingsButtonTapped {
  [self presentInPageCameraSettingsPanel];
}

- (void)presentInPageCameraSettingsPanel {
  __weak typeof(self) weakSelf = self;
  [self presentCardPanelWithTitle:@"相机设置" subtitle:@"全部选项集中展示，点击即生效" bodyBuilder:^(UIStackView *stackView) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (strongSelf == nil) {
      return;
    }

    [stackView addArrangedSubview:[strongSelf createInlineSegmentGroupWithTitle:@"拍照比例"
                                                                           items:@[@"全屏", @"4:3", @"16:9", @"1:1"]
                                                                   selectedIndex:[strongSelf currentRatioSegmentIndex]
                                                                          action:@selector(onRatioSegmentChanged:)]];
    [stackView addArrangedSubview:[strongSelf createInlineSegmentGroupWithTitle:@"网格样式"
                                                                           items:@[@"关闭", @"九宫格", @"米字格"]
                                                                   selectedIndex:self.gridOverlayView.gridStyle
                                                                          action:@selector(onGridSegmentChanged:)]];
    [stackView addArrangedSubview:[strongSelf createInlineSegmentGroupWithTitle:@"计时拍照"
                                                                           items:@[@"关闭", @"3秒", @"5秒"]
                                                                   selectedIndex:[strongSelf currentTimerSegmentIndex]
                                                                          action:@selector(onTimerSegmentChanged:)]];

    if ([strongSelf isTiltShiftSupported]) {
      [stackView addArrangedSubview:[strongSelf createNavRowWithIcon:@"移"
                                                              title:@"移轴"
                                                              value:@"可用"
                                                             action:@selector(onTiltShiftRowTapped)]];
    }

    UIButton *closeButton = [strongSelf createPanelActionButtonWithTitle:@"关闭"
                                                             backgroundHex:0x111827
                                                                   textHex:0xFFFFFF];
    [closeButton addTarget:strongSelf action:@selector(dismissSettingsPanel) forControlEvents:UIControlEventTouchUpInside];
    [stackView addArrangedSubview:closeButton];
  }];
}

- (NSInteger)currentRatioSegmentIndex {
  if (fabs(self.desiredCaptureRatio - (4.0 / 3.0)) < 0.01) {
    return 1;
  }
  if (fabs(self.desiredCaptureRatio - (16.0 / 9.0)) < 0.01) {
    return 2;
  }
  if (fabs(self.desiredCaptureRatio - 1.0) < 0.01) {
    return 3;
  }
  return 0;
}

- (NSInteger)currentTimerSegmentIndex {
  if (self.captureTimerSeconds >= 5.0) {
    return 2;
  }
  if (self.captureTimerSeconds >= 3.0) {
    return 1;
  }
  return 0;
}

- (void)onRatioSegmentChanged:(UISegmentedControl *)sender {
  if (sender.selectedSegmentIndex == 1) {
    [self applyCaptureRatio:(4.0 / 3.0)];
  } else if (sender.selectedSegmentIndex == 2) {
    [self applyCaptureRatio:(16.0 / 9.0)];
  } else if (sender.selectedSegmentIndex == 3) {
    [self applyCaptureRatio:1.0];
  } else {
    [self applyCaptureRatio:0.0];
  }
}

- (void)onGridSegmentChanged:(UISegmentedControl *)sender {
  NSInteger index = MAX(0, MIN(sender.selectedSegmentIndex, 2));
  [self applyGridStyle:(CPCameraGridStyle)index];
}

- (void)onTimerSegmentChanged:(UISegmentedControl *)sender {
  if (sender.selectedSegmentIndex == 1) {
    [self applyCaptureTimer:3.0];
  } else if (sender.selectedSegmentIndex == 2) {
    [self applyCaptureTimer:5.0];
  } else {
    [self applyCaptureTimer:0.0];
  }
}

- (void)onTiltShiftRowTapped {
  [self showSettingsUnavailableMessage:@"当前插件暂不支持原生移轴效果"];
}

- (UIColor *)colorWithHex:(NSInteger)hex alpha:(CGFloat)alpha {
  CGFloat r = ((hex >> 16) & 0xFF) / 255.0;
  CGFloat g = ((hex >> 8) & 0xFF) / 255.0;
  CGFloat b = (hex & 0xFF) / 255.0;
  return [UIColor colorWithRed:r green:g blue:b alpha:alpha];
}

- (NSString *)captureRatioLabel {
  if (self.desiredCaptureRatio <= 0.0) {
    return @"全屏";
  }
  if (fabs(self.desiredCaptureRatio - 1.0) < 0.01) {
    return @"1:1";
  }
  if (fabs(self.desiredCaptureRatio - (4.0/3.0)) < 0.01) {
    return @"4:3";
  }
  if (fabs(self.desiredCaptureRatio - (16.0/9.0)) < 0.01) {
    return @"16:9";
  }
  return @"自定义";
}

- (NSString *)gridStyleLabel {
  if (self.gridOverlayView.gridStyle == CPCameraGridStyleThirds) {
    return @"九宫格";
  }
  if (self.gridOverlayView.gridStyle == CPCameraGridStyleRice) {
    return @"米字格";
  }
  return @"关闭";
}

- (NSString *)captureTimerLabel {
  if (self.captureTimerSeconds >= 5.0) {
    return @"5秒";
  }
  if (self.captureTimerSeconds >= 3.0) {
    return @"3秒";
  }
  return @"关闭";
}

- (BOOL)isTiltShiftSupported {
  // Keep the gate explicit for future native implementation.
  return NO;
}

- (void)dismissSettingsPanel {
  if (self.settingsDimView == nil || self.settingsCardView == nil) {
    return;
  }

  UIView *dimView = self.settingsDimView;
  UIView *cardView = self.settingsCardView;
  self.settingsDimView = nil;
  self.settingsCardView = nil;

  [UIView animateWithDuration:0.18 animations:^{
    dimView.alpha = 0.0;
    cardView.alpha = 0.0;
    cardView.transform = CGAffineTransformMakeScale(0.96, 0.96);
  } completion:^(BOOL finished) {
    [dimView removeFromSuperview];
    [cardView removeFromSuperview];
  }];
}

- (void)presentCardPanelWithTitle:(NSString *)title
                         subtitle:(NSString *)subtitle
                      bodyBuilder:(void(^)(UIStackView *stackView))builder {
  if (self.cameraRenderController == nil || self.cameraRenderController.view == nil) {
    return;
  }

  [self dismissSettingsPanel];

  UIView *host = self.cameraRenderController.view;
  UIView *dimView = [[UIView alloc] initWithFrame:host.bounds];
  dimView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  dimView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.35];
  dimView.alpha = 0.0;
  UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissSettingsPanel)];
  [dimView addGestureRecognizer:tap];

  CGFloat panelWidth = MIN(CGRectGetWidth(host.bounds) - 20.0, 360.0);
  if (panelWidth < 280.0) {
    panelWidth = MAX(240.0, CGRectGetWidth(host.bounds) - 12.0);
  }

  UIView *panel = [[UIView alloc] initWithFrame:CGRectMake((CGRectGetWidth(host.bounds) - panelWidth) / 2.0,
                                                           (CGRectGetHeight(host.bounds) - 320.0) / 2.0,
                                                           panelWidth,
                                                           320.0)];
  panel.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
  panel.backgroundColor = [self colorWithHex:0xFAFAFA alpha:1.0];
  panel.layer.cornerRadius = 14.0;
  panel.layer.masksToBounds = YES;
  panel.alpha = 0.0;
  panel.transform = CGAffineTransformMakeScale(0.96, 0.96);

  UIStackView *stack = [[UIStackView alloc] initWithFrame:panel.bounds];
  stack.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  stack.axis = UILayoutConstraintAxisVertical;
  stack.spacing = 6.0;
  stack.layoutMargins = UIEdgeInsetsMake(12.0, 12.0, 12.0, 12.0);
  stack.layoutMarginsRelativeArrangement = YES;

  UILabel *titleLabel = [[UILabel alloc] init];
  titleLabel.text = title;
  titleLabel.textColor = [self colorWithHex:0x1F2937 alpha:1.0];
  titleLabel.font = [UIFont boldSystemFontOfSize:17.0];
  [stack addArrangedSubview:titleLabel];

  UILabel *subtitleLabel = [[UILabel alloc] init];
  subtitleLabel.text = subtitle;
  subtitleLabel.textColor = [self colorWithHex:0x6B7280 alpha:1.0];
  subtitleLabel.font = [UIFont systemFontOfSize:12.0];
  [stack addArrangedSubview:subtitleLabel];

  if (builder != nil) {
    builder(stack);
  }

  [panel addSubview:stack];
  [host addSubview:dimView];
  [host addSubview:panel];

  self.settingsDimView = dimView;
  self.settingsCardView = panel;

  [UIView animateWithDuration:0.18 animations:^{
    dimView.alpha = 1.0;
    panel.alpha = 1.0;
    panel.transform = CGAffineTransformIdentity;
  }];

  if (self.settingsButton != nil) {
    [host bringSubviewToFront:self.settingsButton];
  }
}

- (UIButton *)createNavRowWithIcon:(NSString *)icon
                              title:(NSString *)title
                              value:(NSString *)value
                             action:(SEL)action {
  UIButton *row = [UIButton buttonWithType:UIButtonTypeCustom];
  row.backgroundColor = [UIColor whiteColor];
  row.layer.cornerRadius = 10.0;
  row.clipsToBounds = YES;
  row.contentHorizontalAlignment = UIControlContentHorizontalAlignmentFill;
  row.contentEdgeInsets = UIEdgeInsetsMake(10.0, 10.0, 10.0, 10.0);
  [row.heightAnchor constraintEqualToConstant:46.0].active = YES;

  UIView *iconBadge = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 18, 18)];
  iconBadge.backgroundColor = [self colorWithHex:0xEAF2FF alpha:1.0];
  iconBadge.layer.cornerRadius = 9.0;

  UILabel *iconLabel = [[UILabel alloc] initWithFrame:iconBadge.bounds];
  iconLabel.text = icon;
  iconLabel.textAlignment = NSTextAlignmentCenter;
  iconLabel.textColor = [self colorWithHex:0x1D4ED8 alpha:1.0];
  iconLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightSemibold];
  [iconBadge addSubview:iconLabel];

  UILabel *titleLabel = [[UILabel alloc] init];
  titleLabel.text = title;
  titleLabel.textColor = [self colorWithHex:0x111827 alpha:1.0];
  titleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightMedium];

  UILabel *valueLabel = [[UILabel alloc] init];
  valueLabel.text = [NSString stringWithFormat:@"%@  >", value ?: @""];
  valueLabel.textColor = [self colorWithHex:0x6B7280 alpha:1.0];
  valueLabel.font = [UIFont systemFontOfSize:13.0];

  UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[iconBadge, titleLabel, valueLabel]];
  content.axis = UILayoutConstraintAxisHorizontal;
  content.alignment = UIStackViewAlignmentCenter;
  content.distribution = UIStackViewDistributionFill;
  content.spacing = 10.0;
  content.userInteractionEnabled = NO;

  [valueLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
  [titleLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

  content.translatesAutoresizingMaskIntoConstraints = NO;
  [row addSubview:content];
  [NSLayoutConstraint activateConstraints:@[
    [content.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:10.0],
    [content.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-10.0],
    [content.topAnchor constraintEqualToAnchor:row.topAnchor constant:10.0],
    [content.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-10.0]
  ]];

  [row addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
  return row;
}

- (UIButton *)createPanelActionButtonWithTitle:(NSString *)title
                                  backgroundHex:(NSInteger)backgroundHex
                                        textHex:(NSInteger)textHex {
  UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
  [button setTitle:title forState:UIControlStateNormal];
  [button setTitleColor:[self colorWithHex:textHex alpha:1.0] forState:UIControlStateNormal];
  button.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
  button.backgroundColor = [self colorWithHex:backgroundHex alpha:1.0];
  button.layer.cornerRadius = 9.0;
  [button.heightAnchor constraintEqualToConstant:36.0].active = YES;
  return button;
}

- (UIView *)createInlineSegmentGroupWithTitle:(NSString *)title
                                         items:(NSArray<NSString *> *)items
                                 selectedIndex:(NSInteger)selectedIndex
                                        action:(SEL)action {
  UIStackView *group = [[UIStackView alloc] init];
  group.axis = UILayoutConstraintAxisVertical;
  group.spacing = 4.0;

  UILabel *titleLabel = [[UILabel alloc] init];
  titleLabel.text = title;
  titleLabel.textColor = [self colorWithHex:0x4B5563 alpha:1.0];
  titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium];
  [group addArrangedSubview:titleLabel];

  UISegmentedControl *segment = [[UISegmentedControl alloc] initWithItems:items];
  segment.selectedSegmentIndex = MAX(0, MIN(selectedIndex, (NSInteger)items.count - 1));
  segment.backgroundColor = [UIColor whiteColor];
  segment.selectedSegmentTintColor = [self colorWithHex:0xEAF2FF alpha:1.0];
  NSDictionary *normalAttrs = @{
    NSForegroundColorAttributeName: [self colorWithHex:0x374151 alpha:1.0],
    NSFontAttributeName: [UIFont systemFontOfSize:12.0 weight:UIFontWeightMedium]
  };
  NSDictionary *selectedAttrs = @{
    NSForegroundColorAttributeName: [self colorWithHex:0x1D4ED8 alpha:1.0],
    NSFontAttributeName: [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold]
  };
  [segment setTitleTextAttributes:normalAttrs forState:UIControlStateNormal];
  [segment setTitleTextAttributes:selectedAttrs forState:UIControlStateSelected];
  [segment addTarget:self action:action forControlEvents:UIControlEventValueChanged];
  [segment.heightAnchor constraintEqualToConstant:32.0].active = YES;
  [group addArrangedSubview:segment];

  return group;
}

- (void)applyCaptureRatio:(CGFloat)ratio {
  self.desiredCaptureRatio = ratio;

  if (self.cameraRenderController == nil || self.cameraRenderController.view.superview == nil) {
    return;
  }

  CGRect container = self.previewContainerFrame;
  if (container.size.width <= 0 || container.size.height <= 0) {
    container = self.cameraRenderController.view.frame;
  }

  CGRect targetFrame = container;
  if (ratio > 0.0f) {
    CGFloat containerRatio = container.size.width / container.size.height;
    if (containerRatio > ratio) {
      CGFloat targetWidth = container.size.height * ratio;
      targetFrame.origin.x = container.origin.x + (container.size.width - targetWidth) / 2.0;
      targetFrame.size.width = targetWidth;
      targetFrame.size.height = container.size.height;
    } else {
      CGFloat targetHeight = container.size.width / ratio;
      targetFrame.origin.y = container.origin.y + (container.size.height - targetHeight) / 2.0;
      targetFrame.size.width = container.size.width;
      targetFrame.size.height = targetHeight;
    }
  }

  self.cameraRenderController.view.frame = targetFrame;
  self.gridOverlayView.frame = self.cameraRenderController.view.bounds;
  [self.cameraRenderController.view bringSubviewToFront:self.settingsButton];
}

- (void)applyGridStyle:(CPCameraGridStyle)style {
  if (self.gridOverlayView == nil) {
    return;
  }
  self.gridOverlayView.gridStyle = style;
}

- (void)applyCaptureTimer:(NSTimeInterval)seconds {
  self.captureTimerSeconds = MAX(0.0, seconds);
}

- (void) showSettingsUnavailableMessage:(NSString *)message {
  dispatch_async(dispatch_get_main_queue(), ^{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"提示"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *okAction = [UIAlertAction actionWithTitle:@"确定"
                                                       style:UIAlertActionStyleDefault
                                                     handler:nil];
    [alert addAction:okAction];
    [self.viewController presentViewController:alert animated:YES completion:nil];
  });
}

- (void) stopCamera:(CDVInvokedUrlCommand*)command {
    NSLog(@"stopCamera");
    CDVPluginResult *pluginResult;

    if(self.sessionManager != nil) {
      self.pendingResumeWhenActive = NO;
      [self stopCaptureSession:@"stopCamera"];
      [self dismissSettingsPanel];
        [self.settingsButton removeFromSuperview];
        self.settingsButton = nil;
        [self.cameraRenderController.view removeFromSuperview];
        [self.cameraRenderController removeFromParentViewController];
        if (self.previewBackgroundView != nil) {
          [self.previewBackgroundView removeFromSuperview];
          self.previewBackgroundView = nil;
        }
        [self.gridOverlayView removeFromSuperview];
        self.gridOverlayView = nil;

        self.cameraRenderController = nil;
        self.sessionManager = nil;

        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    }
    else {
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Camera not started"];
    }

    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void) hideCamera:(CDVInvokedUrlCommand*)command {
  NSLog(@"hideCamera");
  CDVPluginResult *pluginResult;

  if (self.cameraRenderController != nil) {
    self.pendingResumeWhenActive = NO;
    [self.cameraRenderController.view setHidden:YES];
    [self stopCaptureSession:@"hideCamera"];
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
  } else {
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Camera not started"];
  }

  [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void) showCamera:(CDVInvokedUrlCommand*)command {
  NSLog(@"showCamera");
  CDVPluginResult *pluginResult;

  if (self.cameraRenderController != nil) {
    [self.cameraRenderController.view setHidden:NO];
    [self startCaptureSessionIfAllowed:@"showCamera"];
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
  } else {
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Camera not started"];
  }

  [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void) switchCamera:(CDVInvokedUrlCommand*)command {
  NSLog(@"switchCamera");
  CDVPluginResult *pluginResult;

  if (self.sessionManager != nil) {
    [self.sessionManager switchCamera:^(BOOL switched) {

      [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];

    }];

  } else {

    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Session not started"];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
  }
}

- (void) setPreviewBackgroundColor:(CDVInvokedUrlCommand*)command {
  NSString *backgroundColor = command.arguments.count > 0 ? command.arguments[0] : nil;

  // parse color similar to startCamera
  UIColor *bgColorUIColor = [UIColor blackColor];
  if ([backgroundColor isKindOfClass:[NSString class]] && ((NSString*)backgroundColor).length > 0) {
    NSString *bg = (NSString*)backgroundColor;
    if ([[bg lowercaseString] isEqualToString:@"transparent"]) {
      bgColorUIColor = [UIColor clearColor];
    } else {
      NSString *c = bg;
      if ([c hasPrefix:@"#"]) {
        c = [c substringFromIndex:1];
      }
      unsigned int hex = 0;
      NSScanner *scanner = [NSScanner scannerWithString:c];
      [scanner scanHexInt:&hex];
      if (c.length == 6) {
        bgColorUIColor = [self colorWithHex:hex alpha:1.0];
      } else if (c.length == 8) {
        CGFloat a = ((hex >> 24) & 0xFF) / 255.0;
        NSInteger rgb = hex & 0xFFFFFF;
        bgColorUIColor = [self colorWithHex:rgb alpha:a];
      } else {
        bgColorUIColor = [self colorWithHex:hex alpha:1.0];
      }
    }
  }

  dispatch_async(dispatch_get_main_queue(), ^{
    if (self.previewBackgroundView == nil) {
      self.previewBackgroundView = [[UIView alloc] initWithFrame:self.viewController.view.bounds];
      self.previewBackgroundView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    }

    self.previewBackgroundView.backgroundColor = bgColorUIColor;

    if (self.cameraRenderController != nil && self.cameraRenderController.view.superview != nil) {
      // insert background below camera view
      [self.cameraRenderController.view.superview insertSubview:self.previewBackgroundView belowSubview:self.cameraRenderController.view];
    } else {
      // fallback: add at bottom of main view
      if (![self.previewBackgroundView isDescendantOfView:self.viewController.view]) {
        [self.viewController.view insertSubview:self.previewBackgroundView atIndex:0];
      }
    }

    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
  });
}

- (void) getSupportedFocusModes:(CDVInvokedUrlCommand*)command {
  CDVPluginResult *pluginResult;

  if (self.sessionManager != nil) {
    NSArray * focusModes = [self.sessionManager getFocusModes];
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:focusModes];
  } else {
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Session not started"];
  }

  [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void) getFocusMode:(CDVInvokedUrlCommand*)command {
  CDVPluginResult *pluginResult;

  if (self.sessionManager != nil) {
    NSString * focusMode = [self.sessionManager getFocusMode];
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:focusMode];
  } else {
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Session not started"];
  }

  [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void) setFocusMode:(CDVInvokedUrlCommand*)command {
  CDVPluginResult *pluginResult;

  NSString * focusMode = [command.arguments objectAtIndex:0];
  if (self.sessionManager != nil) {
    [self.sessionManager setFocusMode:focusMode];
    NSString * focusMode = [self.sessionManager getFocusMode];
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:focusMode ];
  } else {
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Session not started"];
  }
  [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void) getSupportedFlashModes:(CDVInvokedUrlCommand*)command {
  CDVPluginResult *pluginResult;

  if (self.sessionManager != nil) {
    NSArray * flashModes = [self.sessionManager getFlashModes];
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:flashModes];
  } else {
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Session not started"];
  }

  [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void) getFlashMode:(CDVInvokedUrlCommand*)command {

  CDVPluginResult *pluginResult;

  if (self.sessionManager != nil) {
    BOOL isTorchActive = [self.sessionManager isTorchActive];
    NSInteger flashMode = [self.sessionManager getFlashMode];
    NSString * sFlashMode;
    if (isTorchActive) {
      sFlashMode = @"torch";
    } else {
      if (flashMode == 0) {
        sFlashMode = @"off";
      } else if (flashMode == 1) {
        sFlashMode = @"on";
      } else if (flashMode == 2) {
        sFlashMode = @"auto";
      } else {
        sFlashMode = @"unsupported";
      }
    }
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:sFlashMode ];
  } else {
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Session not started"];
  }

  [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void) setFlashMode:(CDVInvokedUrlCommand*)command {
  NSLog(@"Flash Mode");
  NSString *errMsg;
  CDVPluginResult *pluginResult;

  NSString *flashMode = [command.arguments objectAtIndex:0];

  if (self.sessionManager != nil) {
    if ([flashMode isEqual: @"off"]) {
      [self.sessionManager setFlashMode:AVCaptureFlashModeOff];
    } else if ([flashMode isEqual: @"on"]) {
      [self.sessionManager setFlashMode:AVCaptureFlashModeOn];
    } else if ([flashMode isEqual: @"auto"]) {
      [self.sessionManager setFlashMode:AVCaptureFlashModeAuto];
    } else if ([flashMode isEqual: @"torch"]) {
      [self.sessionManager setTorchMode];
    } else {
      errMsg = @"Flash Mode not supported";
    }
  } else {
    errMsg = @"Session not started";
  }

  if (errMsg) {
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:errMsg];
  } else {
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
  }

  [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void) setZoom:(CDVInvokedUrlCommand*)command {
  NSLog(@"Zoom");
  CDVPluginResult *pluginResult;

  CGFloat desiredZoomFactor = [[command.arguments objectAtIndex:0] floatValue];

  if (self.sessionManager != nil) {
    [self.sessionManager setZoom:desiredZoomFactor];
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
  } else {
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Session not started"];
  }

  [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void) getZoom:(CDVInvokedUrlCommand*)command {

  CDVPluginResult *pluginResult;

  if (self.sessionManager != nil) {
    CGFloat zoom = [self.sessionManager getZoom];
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDouble:zoom ];
  } else {
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Session not started"];
  }

  [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void) getHorizontalFOV:(CDVInvokedUrlCommand*)command {

  CDVPluginResult *pluginResult;

  if (self.sessionManager != nil) {
    float fov = [self.sessionManager getHorizontalFOV];
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDouble:fov ];
  } else {
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Session not started"];
  }

  [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void) getMaxZoom:(CDVInvokedUrlCommand*)command {
  CDVPluginResult *pluginResult;

  if (self.sessionManager != nil) {
    CGFloat maxZoom = [self.sessionManager getMaxZoom];
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDouble:maxZoom ];
  } else {
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Session not started"];
  }

  [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void) getExposureModes:(CDVInvokedUrlCommand*)command {
  CDVPluginResult *pluginResult;

  if (self.sessionManager != nil) {
    NSArray * exposureModes = [self.sessionManager getExposureModes];
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:exposureModes];
  } else {
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Session not started"];
  }

  [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void) getExposureMode:(CDVInvokedUrlCommand*)command {
  CDVPluginResult *pluginResult;

  if (self.sessionManager != nil) {
    NSString * exposureMode = [self.sessionManager getExposureMode];
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:exposureMode ];
  } else {
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Session not started"];
  }

  [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void) setExposureMode:(CDVInvokedUrlCommand*)command {
  CDVPluginResult *pluginResult;

  NSString * exposureMode = [command.arguments objectAtIndex:0];
  if (self.sessionManager != nil) {
    [self.sessionManager setExposureMode:exposureMode];
    NSString * exposureMode = [self.sessionManager getExposureMode];
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:exposureMode ];
  } else {
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Session not started"];
  }
  [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void) getSupportedWhiteBalanceModes:(CDVInvokedUrlCommand*)command {
  CDVPluginResult *pluginResult;

  if (self.sessionManager != nil) {
    NSArray * whiteBalanceModes = [self.sessionManager getSupportedWhiteBalanceModes];
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:whiteBalanceModes ];
  } else {
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Session not started"];
  }

  [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void) getWhiteBalanceMode:(CDVInvokedUrlCommand*)command {
  CDVPluginResult *pluginResult;

  if (self.sessionManager != nil) {
    NSString * whiteBalanceMode = [self.sessionManager getWhiteBalanceMode];
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:whiteBalanceMode ];
  } else {
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Session not started"];
  }

  [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void) setWhiteBalanceMode:(CDVInvokedUrlCommand*)command {
  CDVPluginResult *pluginResult;

  NSString * whiteBalanceMode = [command.arguments objectAtIndex:0];
  if (self.sessionManager != nil) {
    [self.sessionManager setWhiteBalanceMode:whiteBalanceMode];
    NSString * wbMode = [self.sessionManager getWhiteBalanceMode];
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:wbMode ];
  } else {
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Session not started"];
  }
  [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void) getExposureCompensationRange:(CDVInvokedUrlCommand*)command {
  CDVPluginResult *pluginResult;

  if (self.sessionManager != nil) {
    NSArray * exposureRange = [self.sessionManager getExposureCompensationRange];
    NSMutableDictionary *dimensions = [[NSMutableDictionary alloc] init];
    [dimensions setValue:exposureRange[0] forKey:@"min"];
    [dimensions setValue:exposureRange[1] forKey:@"max"];
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:dimensions];
  } else {
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Session not started"];
  }
  [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void) getExposureCompensation:(CDVInvokedUrlCommand*)command {
  CDVPluginResult *pluginResult;

  if (self.sessionManager != nil) {
    CGFloat exposureCompensation = [self.sessionManager getExposureCompensation];
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDouble:exposureCompensation ];
  } else {
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Session not started"];
  }

  [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void) setExposureCompensation:(CDVInvokedUrlCommand*)command {
  NSLog(@"Zoom");
  CDVPluginResult *pluginResult;

  CGFloat exposureCompensation = [[command.arguments objectAtIndex:0] floatValue];

  if (self.sessionManager != nil) {
    [self.sessionManager setExposureCompensation:exposureCompensation];
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDouble:exposureCompensation];
  } else {
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Session not started"];
  }

  [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void) takePicture:(CDVInvokedUrlCommand*)command {
  NSLog(@"takePicture");
  NSLog(@"[CameraPreview][takePicture] callbackId=%@ argsCount=%lu", command.callbackId, (unsigned long)command.arguments.count);
  CDVPluginResult *pluginResult;

  if (self.cameraRenderController != NULL) {
    if (command.arguments.count < 3) {
      pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Invalid number of parameters"];
      [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
      return;
    }

    self.onPictureTakenHandlerId = command.callbackId;

    CGFloat width = (CGFloat)[command.arguments[0] floatValue];
    CGFloat height = (CGFloat)[command.arguments[1] floatValue];
    CGFloat quality = (CGFloat)[command.arguments[2] floatValue] / 100.0f;

    [self invokeTakePicture:width withHeight:height withQuality:quality callbackId:command.callbackId];
  } else {
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Camera not started"];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
  }
}

- (void) takeSnapshot:(CDVInvokedUrlCommand*)command {
    NSLog(@"takeSnapshot");
    CDVPluginResult *pluginResult;
    if (self.cameraRenderController != NULL && self.cameraRenderController.view != NULL) {
        CGFloat quality = (CGFloat)[command.arguments[0] floatValue] / 100.0f;
        dispatch_async(self.sessionManager.sessionQueue, ^{
            UIImage *image = ((GLKView*)self.cameraRenderController.view).snapshot;
      CDVPluginResult *pluginResult = nil;

      if (self.shouldStoreToFile) {
        NSData *data = UIImageJPEGRepresentation(image, (CGFloat) quality);
        NSString* filePath = [self getTempFilePath:@"jpg"];
        NSError *err;

        BOOL writeOK = [data writeToFile:filePath options:NSAtomicWrite error:&err];
        pluginResult = [self pluginResultForStoredImageAtPath:filePath writeError:(writeOK ? nil : err)];
      } else {
        NSString *base64Image = [self getBase64Image:image.CGImage withQuality:quality];
        NSMutableArray *params = [[NSMutableArray alloc] init];
        [params addObject:base64Image];
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:params];
      }
            [pluginResult setKeepCallbackAsBool:false];
            [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
        });
    } else {
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Camera not started"];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
    }
}


-(void) setColorEffect:(CDVInvokedUrlCommand*)command {
  NSLog(@"setColorEffect");
  CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
  NSString *filterName = command.arguments[0];

  if(self.sessionManager != nil){
    if ([filterName isEqual: @"none"]) {
      dispatch_async(self.sessionManager.sessionQueue, ^{
          [self.sessionManager setCiFilter:nil];
          });
    } else if ([filterName isEqual: @"mono"]) {
      dispatch_async(self.sessionManager.sessionQueue, ^{
          CIFilter *filter = [CIFilter filterWithName:@"CIColorMonochrome"];
          [filter setDefaults];
          [self.sessionManager setCiFilter:filter];
          });
    } else if ([filterName isEqual: @"negative"]) {
      dispatch_async(self.sessionManager.sessionQueue, ^{
          CIFilter *filter = [CIFilter filterWithName:@"CIColorInvert"];
          [filter setDefaults];
          [self.sessionManager setCiFilter:filter];
          });
    } else if ([filterName isEqual: @"posterize"]) {
      dispatch_async(self.sessionManager.sessionQueue, ^{
          CIFilter *filter = [CIFilter filterWithName:@"CIColorPosterize"];
          [filter setDefaults];
          [self.sessionManager setCiFilter:filter];
          });
    } else if ([filterName isEqual: @"sepia"]) {
      dispatch_async(self.sessionManager.sessionQueue, ^{
          CIFilter *filter = [CIFilter filterWithName:@"CISepiaTone"];
          [filter setDefaults];
          [self.sessionManager setCiFilter:filter];
          });
    } else {
      pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Filter not found"];
    }
  } else {
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Session not started"];
  }

  [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void) setPreviewSize: (CDVInvokedUrlCommand*)command {

    if (self.sessionManager == nil || self.cameraRenderController == nil) {
      CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Session not started"];
      [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
      return;
    }

    if (command.arguments.count < 2) {
      CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Invalid number of parameters"];
      [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
      return;
    }

    CGFloat width = (CGFloat)[command.arguments[0] floatValue];
    CGFloat height = (CGFloat)[command.arguments[1] floatValue];
    if (width <= 0 || height <= 0) {
      CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Invalid preview size"];
      [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
      return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
      CGRect container = self.previewContainerFrame;
      if (container.size.width <= 0 || container.size.height <= 0) {
        container = self.cameraRenderController.view.frame;
      }

      // Keep the current preview position and only update the container size.
      container.size.width = width;
      container.size.height = height;
      self.previewContainerFrame = container;

      [self applyCaptureRatio:self.desiredCaptureRatio];

      NSDictionary *result = @{
        @"width": @(CGRectGetWidth(self.cameraRenderController.view.frame)),
        @"height": @(CGRectGetHeight(self.cameraRenderController.view.frame))
      };
      CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:result];
      [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
    });
}

- (void) setCaptureRatio:(CDVInvokedUrlCommand*)command {
  CDVPluginResult *pluginResult;

  if (self.cameraRenderController == nil) {
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Session not started"];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
    return;
  }

  id arg = command.arguments.count > 0 ? command.arguments[0] : nil;
  CGFloat ratio = 0.0;
  if ([arg isKindOfClass:[NSString class]]) {
    NSString *s = (NSString*)arg;
    if ([s isEqualToString:@"full"]) {
      ratio = 0.0;
    } else if ([s isEqualToString:@"4:3"]) {
      ratio = 4.0/3.0;
    } else if ([s isEqualToString:@"16:9"]) {
      ratio = 16.0/9.0;
    } else if ([s isEqualToString:@"1:1"]) {
      ratio = 1.0;
    } else {
      ratio = 0.0;
    }
  } else if ([arg isKindOfClass:[NSNumber class]]) {
    ratio = [arg doubleValue];
  }

  dispatch_async(dispatch_get_main_queue(), ^{
    [self applyCaptureRatio:ratio];
  });

  pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
  [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void) setCaptureTimer:(CDVInvokedUrlCommand*)command {
  CDVPluginResult *pluginResult;

  if (self.cameraRenderController == nil) {
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Session not started"];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
    return;
  }

  id arg = command.arguments.count > 0 ? command.arguments[0] : nil;
  NSTimeInterval seconds = 0.0;
  if ([arg isKindOfClass:[NSNumber class]]) {
    seconds = [arg doubleValue];
  } else if ([arg isKindOfClass:[NSString class]]) {
    seconds = [(NSString*)arg doubleValue];
  }

  dispatch_async(dispatch_get_main_queue(), ^{
    [self applyCaptureTimer:seconds];
  });

  pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDouble:seconds];
  [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void) setStoreToFile:(CDVInvokedUrlCommand*)command {
  CDVPluginResult *pluginResult;

  if (command.arguments.count == 0) {
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Invalid parameters"];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
    return;
  }

  BOOL store = [[command.arguments objectAtIndex:0] boolValue];
  self.shouldStoreToFile = store;

  pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
  [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void) setPreviewPosition:(CDVInvokedUrlCommand*)command {
  CDVPluginResult *pluginResult;

  if (self.cameraRenderController == nil) {
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Session not started"];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
    return;
  }

  if (command.arguments.count < 2) {
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Invalid parameters"];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
    return;
  }

  CGFloat x = (CGFloat)[[command.arguments objectAtIndex:0] floatValue] + self.webView.frame.origin.x;
  CGFloat y = (CGFloat)[[command.arguments objectAtIndex:1] floatValue] + self.webView.frame.origin.y;

  dispatch_async(dispatch_get_main_queue(), ^{
    CGRect frame = self.cameraRenderController.view.frame;
    frame.origin.x = x;
    frame.origin.y = y;
    self.cameraRenderController.view.frame = frame;
    self.previewContainerFrame = frame;
    [self applyCaptureRatio:self.desiredCaptureRatio];
  });

  pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
  [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void) getSupportedPictureSizes:(CDVInvokedUrlCommand*)command {
  NSLog(@"getSupportedPictureSizes");
  CDVPluginResult *pluginResult;

  if(self.sessionManager != nil){
    NSArray *formats = self.sessionManager.getDeviceFormats;
    NSMutableArray *jsonFormats = [NSMutableArray new];
    int lastWidth = 0;
    int lastHeight = 0;
    for (AVCaptureDeviceFormat *format in formats) {
      CMVideoDimensions dim = format.highResolutionStillImageDimensions;
      if (dim.width!=lastWidth && dim.height != lastHeight) {
        NSMutableDictionary *dimensions = [[NSMutableDictionary alloc] init];
        NSNumber *width = [NSNumber numberWithInt:dim.width];
        NSNumber *height = [NSNumber numberWithInt:dim.height];
        [dimensions setValue:width forKey:@"width"];
        [dimensions setValue:height forKey:@"height"];
        [jsonFormats addObject:dimensions];
        lastWidth = dim.width;
        lastHeight = dim.height;
      }
    }
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:jsonFormats];

  } else {
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Session not started"];
  }

  [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (NSString *)getBase64Image:(CGImageRef)imageRef withQuality:(CGFloat) quality {
  NSString *base64Image = nil;

  @try {
    UIImage *image = [UIImage imageWithCGImage:imageRef];
    NSData *imageData = UIImageJPEGRepresentation(image, quality);
    base64Image = [imageData base64EncodedStringWithOptions:0];
  }
  @catch (NSException *exception) {
    NSLog(@"error while get base64Image: %@", [exception reason]);
  }

  return base64Image;
}

- (void) tapToFocus:(CDVInvokedUrlCommand*)command {
  NSLog(@"tapToFocus");
  CDVPluginResult *pluginResult;

  CGFloat xPoint = [[command.arguments objectAtIndex:0] floatValue];
  CGFloat yPoint = [[command.arguments objectAtIndex:1] floatValue];

  if (self.sessionManager != nil) {
    [self.sessionManager tapToFocus:xPoint yPoint:yPoint];
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
  } else {
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Session not started"];
  }

  [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (double)radiansFromVideoOrientation:(AVCaptureVideoOrientation)videoOrientation {
  switch (videoOrientation) {
    case AVCaptureVideoOrientationPortrait:
      return M_PI_2;
    case AVCaptureVideoOrientationLandscapeLeft:
      return 0.f;
    case AVCaptureVideoOrientationLandscapeRight:
      return M_PI;
    case AVCaptureVideoOrientationPortraitUpsideDown:
      return -M_PI_2;
    default:
      return 0.f;
  }
}

-(CGImageRef) CGImageRotated:(CGImageRef) originalCGImage withRadians:(double) radians {
  CGSize imageSize = CGSizeMake(CGImageGetWidth(originalCGImage), CGImageGetHeight(originalCGImage));
  CGSize rotatedSize;
  if (radians == M_PI_2 || radians == -M_PI_2) {
    rotatedSize = CGSizeMake(imageSize.height, imageSize.width);
  } else {
    rotatedSize = imageSize;
  }

  double rotatedCenterX = rotatedSize.width / 2.f;
  double rotatedCenterY = rotatedSize.height / 2.f;

  UIGraphicsBeginImageContextWithOptions(rotatedSize, NO, 1.f);
  CGContextRef rotatedContext = UIGraphicsGetCurrentContext();
  if (radians == 0.f || radians == M_PI) { // 0 or 180 degrees
    CGContextTranslateCTM(rotatedContext, rotatedCenterX, rotatedCenterY);
    if (radians == 0.0f) {
      CGContextScaleCTM(rotatedContext, 1.f, -1.f);
    } else {
      CGContextScaleCTM(rotatedContext, -1.f, 1.f);
    }
    CGContextTranslateCTM(rotatedContext, -rotatedCenterX, -rotatedCenterY);
  } else if (radians == M_PI_2 || radians == -M_PI_2) { // +/- 90 degrees
    CGContextTranslateCTM(rotatedContext, rotatedCenterX, rotatedCenterY);
    CGContextRotateCTM(rotatedContext, radians);
    CGContextScaleCTM(rotatedContext, 1.f, -1.f);
    CGContextTranslateCTM(rotatedContext, -rotatedCenterY, -rotatedCenterX);
  }

  CGRect drawingRect = CGRectMake(0.f, 0.f, imageSize.width, imageSize.height);
  CGContextDrawImage(rotatedContext, drawingRect, originalCGImage);
  CGImageRef rotatedCGImage = CGBitmapContextCreateImage(rotatedContext);

  UIGraphicsEndImageContext();

  return rotatedCGImage;
}

- (void) invokeTapToFocus:(CGPoint)point {
  [self.sessionManager tapToFocus:point.x yPoint:point.y];
}

- (void)sendPicturePluginResult:(CDVPluginResult *)pluginResult callbackId:(NSString *)callbackId keepCallback:(BOOL)keep {
  if (callbackId == nil || callbackId.length == 0) {
    NSLog(@"[CameraPreview] skip plugin result: callbackId is nil/empty");
    return;
  }

  CDVPluginResult *result = pluginResult;
  if (result == nil) {
    result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Failed to process captured image"];
  }

  [result setKeepCallbackAsBool:keep];
  NSLog(@"[CameraPreview][sendPicturePluginResult] callbackId=%@ keep=%@",
        callbackId,
        keep ? @"YES" : @"NO");
  [self.commandDelegate sendPluginResult:result callbackId:callbackId];
  NSLog(@"[CameraPreview][sendPicturePluginResult] callback sent for callbackId=%@", callbackId);
}

- (NSData *)jpegDataFromSampleBuffer:(CMSampleBufferRef)sampleBuffer quality:(CGFloat)quality {
  if (sampleBuffer == NULL) {
    return nil;
  }

  NSData *imageData = [AVCaptureStillImageOutput jpegStillImageNSDataRepresentation:sampleBuffer];
  if (imageData != nil && imageData.length > 0) {
    return imageData;
  }

  CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
  if (imageBuffer == NULL) {
    return nil;
  }

  CIImage *ciImage = [CIImage imageWithCVPixelBuffer:imageBuffer];
  CIContext *context = [CIContext contextWithOptions:nil];
  CGImageRef cgImage = [context createCGImage:ciImage fromRect:ciImage.extent];
  if (cgImage == nil) {
    return nil;
  }

  UIImage *image = [UIImage imageWithCGImage:cgImage];
  CGImageRelease(cgImage);

  CGFloat clampedQuality = quality;
  if (clampedQuality <= 0.0f || clampedQuality > 1.0f) {
    clampedQuality = 0.85f;
  }

  return UIImageJPEGRepresentation(image, clampedQuality);
}

- (CDVPluginResult *)pluginResultForStoredImageAtPath:(NSString *)filePath writeError:(NSError *)writeError {
  if (writeError != nil) {
    return [CDVPluginResult resultWithStatus:CDVCommandStatus_IO_EXCEPTION messageAsString:[writeError localizedDescription]];
  }

  if (filePath == nil || filePath.length == 0) {
    return [CDVPluginResult resultWithStatus:CDVCommandStatus_IO_EXCEPTION messageAsString:@"Invalid image file path"];
  }

  BOOL fileExists = [[NSFileManager defaultManager] fileExistsAtPath:filePath];
  if (!fileExists) {
    return [CDVPluginResult resultWithStatus:CDVCommandStatus_IO_EXCEPTION messageAsString:@"Image file not found after write"];
  }

  NSMutableArray *params = [[NSMutableArray alloc] initWithObjects:filePath, nil];
  return [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:params];
}

- (void) invokeTakePicture {
  [self invokeTakePicture:0.0 withHeight:0.0 withQuality:0.85 callbackId:self.onPictureTakenHandlerId];
}

- (void) invokeTakePicture:(CGFloat) width withHeight:(CGFloat) height withQuality:(CGFloat) quality {
  [self invokeTakePicture:width withHeight:height withQuality:quality callbackId:self.onPictureTakenHandlerId];
}

- (void) invokeTakePictureOnFocus {
    // the sessionManager will call onFocus, as soon as the camera is done with focussing.
  [self.sessionManager takePictureOnFocus];
}

- (void) capturePictureNow:(CGFloat) width withHeight:(CGFloat) height withQuality:(CGFloat) quality callbackId:(NSString *)callbackId {
    if (callbackId == nil || callbackId.length == 0) {
      NSLog(@"[CameraPreview][capturePictureNow] ERROR: callbackId is nil/empty, abort capture");
      return;
    }

    AVCaptureConnection *connection = [self.sessionManager.stillImageOutput connectionWithMediaType:AVMediaTypeVideo];

    if (connection == nil) {
      NSLog(@"[CameraPreview][capturePictureNow] ERROR: no video connection available");
      CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"No video connection available"];
      [self sendPicturePluginResult:pluginResult callbackId:callbackId keepCallback:self.cameraRenderController.tapToTakePicture];
      return;
    }

    // Capture the CIContext and settings we need on this thread before going async,
    // so the block doesn't access UIKit/view properties from a background thread.
    CIContext *ciContext = self.cameraRenderController.ciContext;
    AVCaptureDevicePosition cameraPosition = self.sessionManager.defaultCamera;
    AVCaptureVideoOrientation videoOrientation = connection.videoOrientation;
    CIFilter *ciFilter = self.sessionManager.ciFilter;
    BOOL storeToFile = self.shouldStoreToFile;
    BOOL keepCallback = NO;
        BOOL needsResize = (width > 0 && height > 0);
        BOOL needsFilter = (ciFilter != nil);
        BOOL requiresHeavyProcessing = needsResize || needsFilter;

        NSLog(@"[CameraPreview][capturePictureNow] begin callbackId=%@ storeToFile=%@ needsResize=%@ needsFilter=%@",
          callbackId,
          storeToFile ? @"YES" : @"NO",
          needsResize ? @"YES" : @"NO",
          needsFilter ? @"YES" : @"NO");

    [self.sessionManager.stillImageOutput captureStillImageAsynchronouslyFromConnection:connection completionHandler:^(CMSampleBufferRef sampleBuffer, NSError *error) {

      NSLog(@"Done creating still image");

      // Keep sampleBuffer alive while we process on a background queue.
      CMSampleBufferRef retainedSampleBuffer = sampleBuffer;
      if (retainedSampleBuffer != NULL) {
        CFRetain(retainedSampleBuffer);
      }

      // --- Move ALL heavy processing off the main thread so WKWebView URL
      //     scheme tasks are not starved while the main run loop is blocked. ---
      dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{

        CGImageRef finalImage = nil;
        CGImageRef resultFinalImage = nil;
        @try {

        if (error) {
          NSLog(@"[CameraPreview][capturePictureNow] capture error: %@", error);
          CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:[error localizedDescription]];
          [self sendPicturePluginResult:pluginResult callbackId:callbackId keepCallback:keepCallback];
          return;
        }

        if (retainedSampleBuffer == NULL) {
          NSLog(@"[CameraPreview][capturePictureNow] ERROR: sampleBuffer is nil");
          CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Failed to capture image: empty buffer"];
          [self sendPicturePluginResult:pluginResult callbackId:callbackId keepCallback:keepCallback];
          return;
        }

        NSData *imageData = [self jpegDataFromSampleBuffer:retainedSampleBuffer quality:quality];
        if (imageData == nil) {
          NSLog(@"[CameraPreview][capturePictureNow] ERROR: imageData is nil");
          CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Failed to encode captured image data"];
          [self sendPicturePluginResult:pluginResult callbackId:callbackId keepCallback:keepCallback];
          return;
        }

        if (storeToFile && !requiresHeavyProcessing) {
          NSLog(@"[CameraPreview][storeToFile] fast path enabled (no resize/filter)");
          NSString *filePath = [self getTempFilePath:@"jpg"];
          NSLog(@"[CameraPreview][storeToFile] writing file: %@", filePath);

          NSError *writeError = nil;
          BOOL writeOK = [imageData writeToFile:filePath options:NSAtomicWrite error:&writeError];
          NSLog(@"[CameraPreview][storeToFile] write result=%@ error=%@",
                writeOK ? @"OK" : @"FAIL",
                writeError != nil ? writeError.localizedDescription : @"none");

          CDVPluginResult *pluginResult = [self pluginResultForStoredImageAtPath:filePath writeError:(writeOK ? nil : writeError)];
          if (writeOK) {
            NSLog(@"[CameraPreview][storeToFile] returning path: %@", filePath);
          }

          [self sendPicturePluginResult:pluginResult callbackId:callbackId keepCallback:keepCallback];
          return;
        }

        if (storeToFile) {
          NSLog(@"[CameraPreview][storeToFile] heavy path enabled (resize/filter requested)");
        }

        UIImage *capturedImage = [[UIImage alloc] initWithData:imageData];

        if (capturedImage == nil || capturedImage.CGImage == nil) {
          CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Failed to decode captured image"];
          [self sendPicturePluginResult:pluginResult callbackId:callbackId keepCallback:keepCallback];
          return;
        }

        CIImage *capturedCImage;
        if (width > 0 && height > 0) {
          CGFloat scaleHeight = width / capturedImage.size.height;
          CGFloat scaleWidth  = height / capturedImage.size.width;
          CGFloat scale = scaleHeight > scaleWidth ? scaleWidth : scaleHeight;

          CIFilter *resizeFilter = [CIFilter filterWithName:@"CILanczosScaleTransform"];
          [resizeFilter setValue:[[CIImage alloc] initWithCGImage:[capturedImage CGImage]] forKey:kCIInputImageKey];
          [resizeFilter setValue:@(1.0f) forKey:@"inputAspectRatio"];
          [resizeFilter setValue:@(scale) forKey:@"inputScale"];
          capturedCImage = [resizeFilter outputImage];
        } else {
          capturedCImage = [[CIImage alloc] initWithCGImage:[capturedImage CGImage]];
        }

        CIImage *imageToFilter;
        if (cameraPosition == AVCaptureDevicePositionFront) {
          CGAffineTransform matrix = CGAffineTransformTranslate(CGAffineTransformMakeScale(1, -1), 0, capturedCImage.extent.size.height);
          imageToFilter = [capturedCImage imageByApplyingTransform:matrix];
        } else {
          imageToFilter = capturedCImage;
        }

        CIImage *finalCImage;
        if (ciFilter != nil) {
          [self.sessionManager.filterLock lock];
          [ciFilter setValue:imageToFilter forKey:kCIInputImageKey];
          finalCImage = [ciFilter outputImage];
          [self.sessionManager.filterLock unlock];
        } else {
          finalCImage = imageToFilter;
        }

        // Use a CPU-backed CIContext so this can safely run off the main thread
        // without contending with the EAGLContext used for preview rendering.
        CIContext *renderContext = ciContext;
        if (renderContext == nil) {
          renderContext = [CIContext contextWithOptions:nil];
        }
        finalImage = [renderContext createCGImage:finalCImage fromRect:finalCImage.extent];
        if (finalImage == nil) {
          CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Failed to render captured image"];
          [self sendPicturePluginResult:pluginResult callbackId:callbackId keepCallback:keepCallback];
          return;
        }

        double radians = [self radiansFromVideoOrientation:videoOrientation];
        resultFinalImage = [self CGImageRotated:finalImage withRadians:radians];
        CGImageRelease(finalImage);
        finalImage = nil;

        CDVPluginResult *pluginResult;
        if (storeToFile) {
          NSLog(@"[CameraPreview][storeToFile] heavy path writing processed image");
          NSData *data = UIImageJPEGRepresentation([UIImage imageWithCGImage:resultFinalImage], (CGFloat)quality);
          NSString *filePath = [self getTempFilePath:@"jpg"];
          NSLog(@"[CameraPreview][storeToFile] writing file: %@", filePath);
          NSError *err;
          BOOL writeOK = (data != nil) && [data writeToFile:filePath options:NSAtomicWrite error:&err];
          NSLog(@"[CameraPreview][storeToFile] write result=%@ error=%@",
                writeOK ? @"OK" : @"FAIL",
                err != nil ? err.localizedDescription : @"none");
          pluginResult = [self pluginResultForStoredImageAtPath:filePath writeError:(writeOK ? nil : err)];
          if (writeOK) {
            NSLog(@"[CameraPreview][storeToFile] returning path: %@", filePath);
          }
        } else {
          NSString *base64Image = [self getBase64Image:resultFinalImage withQuality:quality];
          if (base64Image == nil) {
            pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Failed to encode image"];
          } else {
            NSMutableArray *params = [[NSMutableArray alloc] init];
            [params addObject:base64Image];
            pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:params];
          }
        }

        [self sendPicturePluginResult:pluginResult callbackId:callbackId keepCallback:keepCallback];
        }
        @catch (NSException *exception) {
          NSLog(@"[CameraPreview][capturePictureNow] exception: %@", exception.reason);
          CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Failed to process captured image"];
          [self sendPicturePluginResult:pluginResult callbackId:callbackId keepCallback:keepCallback];
        }
        @finally {
          if (retainedSampleBuffer != NULL) {
            CFRelease(retainedSampleBuffer);
          }
          if (finalImage != nil) {
            CGImageRelease(finalImage);
          }
          if (resultFinalImage != nil) {
            CGImageRelease(resultFinalImage);
          }
        }
      });
    }];
}

- (void) invokeTakePicture:(CGFloat) width withHeight:(CGFloat) height withQuality:(CGFloat) quality callbackId:(NSString *)callbackId {
  if (self.captureTimerSeconds <= 0.0) {
    [self capturePictureNow:width withHeight:height withQuality:quality callbackId:callbackId];
    return;
  }

  __weak typeof(self) weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.captureTimerSeconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (strongSelf == nil || strongSelf.sessionManager == nil || strongSelf.cameraRenderController == nil) {
      if (strongSelf != nil && callbackId != nil) {
        CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Camera not started"];
        [strongSelf sendPicturePluginResult:pluginResult callbackId:callbackId keepCallback:NO];
      }
      return;
    }
    [strongSelf capturePictureNow:width withHeight:height withQuality:quality callbackId:callbackId];
  });
}

- (NSString*)getTempDirectoryPath
{
  NSString* tmpPath = [NSTemporaryDirectory()stringByStandardizingPath];
  return tmpPath;
}

- (NSString*)getTempFilePath:(NSString*)extension
{
    NSString* tmpPath = [self getTempDirectoryPath];
    NSFileManager* fileMgr = [[NSFileManager alloc] init]; // recommended by Apple (vs [NSFileManager defaultManager]) to be threadsafe
    NSString* filePath;

    // generate unique file name
    int i = 1;
    do {
        filePath = [NSString stringWithFormat:@"%@/%@%04d.%@", tmpPath, TMP_IMAGE_PREFIX, i++, extension];
    } while ([fileMgr fileExistsAtPath:filePath]);

    return filePath;
}

@end
