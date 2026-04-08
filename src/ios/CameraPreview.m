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

typedef void (^CPCameraSelectionApplyBlock)(NSInteger selectedIndex);

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
@property (nonatomic, copy) CPCameraSelectionApplyBlock selectionApplyBlock;
@property (nonatomic, strong) NSArray<UIButton *> *selectionOptionButtons;
@property (nonatomic, assign) NSInteger selectionSelectedIndex;

@end

@implementation CameraPreview

-(void) pluginInitialize{
  // start as transparent
  self.webView.opaque = NO;
  self.webView.backgroundColor = [UIColor clearColor];
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
    BOOL tapToFocus = (BOOL) [command.arguments[9] boolValue];
    BOOL disableExifHeaderStripping = (BOOL) [command.arguments[10] boolValue]; // ignore Android only
    self.storeToFile = (BOOL) [command.arguments[11] boolValue];
    BOOL enableAutoSettings = command.arguments.count > 12 ? (BOOL) [command.arguments[12] boolValue] : NO;

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

    [self.viewController addChildViewController:self.cameraRenderController];

    if (toBack) {
      // display the camera below the webview

      // make transparent
      self.webView.opaque = NO;
      self.webView.backgroundColor = [UIColor clearColor];

      self.webView.scrollView.opaque = NO;
      self.webView.scrollView.backgroundColor = [UIColor clearColor];

      [self.viewController.view insertSubview:self.cameraRenderController.view atIndex:0];
      [self.webView.superview bringSubviewToFront:self.webView];
    } else {
      self.cameraRenderController.view.alpha = alpha;
      [self.webView.superview insertSubview:self.cameraRenderController.view aboveSubview:self.webView];
    }

    [self setupIOSSettingsButtonIfNeeded:toBack];

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

- (void) setupIOSSettingsButtonIfNeeded:(BOOL)toBack {
  if (toBack || self.cameraRenderController == nil) {
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
  [self presentCardPanelWithTitle:@"相机设置" subtitle:@"在当前页面调整参数，立即生效" bodyBuilder:^(UIStackView *stackView) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (strongSelf == nil) {
      return;
    }

    [stackView addArrangedSubview:[strongSelf createNavRowWithIcon:@"比"
                                                            title:@"拍照比例"
                                                            value:[strongSelf captureRatioLabel]
                                                           action:@selector(onRatioRowTapped)]];
    [stackView addArrangedSubview:[strongSelf createNavRowWithIcon:@"网"
                                                            title:@"参考线"
                                                            value:[strongSelf gridStyleLabel]
                                                           action:@selector(onGridRowTapped)]];
    [stackView addArrangedSubview:[strongSelf createNavRowWithIcon:@"时"
                                                            title:@"计时拍照"
                                                            value:[strongSelf captureTimerLabel]
                                                           action:@selector(onTimerRowTapped)]];
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

- (void)presentRatioSelectionSheet {
  NSArray<NSString *> *options = @[@"全屏", @"1:1", @"4:3", @"16:9"];
  NSInteger currentIndex = 0;
  if (self.desiredCaptureRatio == 1.0) {
    currentIndex = 1;
  } else if (fabs(self.desiredCaptureRatio - (4.0/3.0)) < 0.01) {
    currentIndex = 2;
  } else if (fabs(self.desiredCaptureRatio - (16.0/9.0)) < 0.01) {
    currentIndex = 3;
  }

  __weak typeof(self) weakSelf = self;
  [self presentSelectionPanelWithTitle:@"拍照比例"
                              subtitle:@"选择预览画面比例"
                               options:options
                          currentIndex:currentIndex
                             onConfirm:^(NSInteger selectedIndex) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (strongSelf == nil) {
      return;
    }
    if (selectedIndex == 1) {
      [strongSelf applyCaptureRatio:1.0];
    } else if (selectedIndex == 2) {
      [strongSelf applyCaptureRatio:(4.0/3.0)];
    } else if (selectedIndex == 3) {
      [strongSelf applyCaptureRatio:(16.0/9.0)];
    } else {
      [strongSelf applyCaptureRatio:0.0];
    }
  }];
}

- (void)presentGridSelectionSheet {
  NSArray<NSString *> *options = @[@"关闭", @"九宫格", @"米字格"];
  NSInteger currentIndex = self.gridOverlayView.gridStyle;
  if (currentIndex < 0 || currentIndex >= (NSInteger)options.count) {
    currentIndex = 0;
  }

  __weak typeof(self) weakSelf = self;
  [self presentSelectionPanelWithTitle:@"参考线"
                              subtitle:@"构图参考线设置"
                               options:options
                          currentIndex:currentIndex
                             onConfirm:^(NSInteger selectedIndex) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (strongSelf == nil) {
      return;
    }
    [strongSelf applyGridStyle:(CPCameraGridStyle)selectedIndex];
  }];
}

- (void)presentTimerSelectionSheet {
  NSArray<NSString *> *options = @[@"关闭", @"3 秒", @"5 秒"];
  NSInteger currentIndex = 0;
  if (self.captureTimerSeconds >= 5.0) {
    currentIndex = 2;
  } else if (self.captureTimerSeconds >= 3.0) {
    currentIndex = 1;
  }

  __weak typeof(self) weakSelf = self;
  [self presentSelectionPanelWithTitle:@"计时拍照"
                              subtitle:@"拍照前延时触发"
                               options:options
                          currentIndex:currentIndex
                             onConfirm:^(NSInteger selectedIndex) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (strongSelf == nil) {
      return;
    }
    if (selectedIndex == 1) {
      [strongSelf applyCaptureTimer:3.0];
    } else if (selectedIndex == 2) {
      [strongSelf applyCaptureTimer:5.0];
    } else {
      [strongSelf applyCaptureTimer:0.0];
    }
  }];
}

- (void)onRatioRowTapped {
  [self presentRatioSelectionSheet];
}

- (void)onGridRowTapped {
  [self presentGridSelectionSheet];
}

- (void)onTimerRowTapped {
  [self presentTimerSelectionSheet];
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
  self.selectionApplyBlock = nil;
  self.selectionOptionButtons = nil;
  self.selectionSelectedIndex = 0;

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

  CGFloat panelWidth = MIN(CGRectGetWidth(host.bounds) - 24.0, 360.0);
  if (panelWidth < 280.0) {
    panelWidth = MAX(240.0, CGRectGetWidth(host.bounds) - 16.0);
  }

  UIView *panel = [[UIView alloc] initWithFrame:CGRectMake((CGRectGetWidth(host.bounds) - panelWidth) / 2.0,
                                                           (CGRectGetHeight(host.bounds) - 340.0) / 2.0,
                                                           panelWidth,
                                                           340.0)];
  panel.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
  panel.backgroundColor = [self colorWithHex:0xFAFAFA alpha:1.0];
  panel.layer.cornerRadius = 16.0;
  panel.layer.masksToBounds = YES;
  panel.alpha = 0.0;
  panel.transform = CGAffineTransformMakeScale(0.96, 0.96);

  UIStackView *stack = [[UIStackView alloc] initWithFrame:panel.bounds];
  stack.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  stack.axis = UILayoutConstraintAxisVertical;
  stack.spacing = 8.0;
  stack.layoutMargins = UIEdgeInsetsMake(16.0, 16.0, 16.0, 16.0);
  stack.layoutMarginsRelativeArrangement = YES;

  UILabel *titleLabel = [[UILabel alloc] init];
  titleLabel.text = title;
  titleLabel.textColor = [self colorWithHex:0x1F2937 alpha:1.0];
  titleLabel.font = [UIFont boldSystemFontOfSize:18.0];
  [stack addArrangedSubview:titleLabel];

  UILabel *subtitleLabel = [[UILabel alloc] init];
  subtitleLabel.text = subtitle;
  subtitleLabel.textColor = [self colorWithHex:0x6B7280 alpha:1.0];
  subtitleLabel.font = [UIFont systemFontOfSize:13.0];
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
  button.layer.cornerRadius = 10.0;
  [button.heightAnchor constraintEqualToConstant:40.0].active = YES;
  return button;
}

- (UIButton *)createSelectableRowWithTitle:(NSString *)title selected:(BOOL)selected {
  UIButton *row = [UIButton buttonWithType:UIButtonTypeCustom];
  row.layer.cornerRadius = 10.0;
  row.contentEdgeInsets = UIEdgeInsetsMake(10.0, 12.0, 10.0, 12.0);
  [row.heightAnchor constraintEqualToConstant:44.0].active = YES;

  UILabel *label = [[UILabel alloc] init];
  label.text = title;
  label.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightMedium];
  label.tag = 2001;

  UILabel *check = [[UILabel alloc] init];
  check.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
  check.text = @"已选";
  check.tag = 2002;

  UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[label, check]];
  content.axis = UILayoutConstraintAxisHorizontal;
  content.alignment = UIStackViewAlignmentCenter;
  content.distribution = UIStackViewDistributionFill;
  content.userInteractionEnabled = NO;
  [check setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

  content.translatesAutoresizingMaskIntoConstraints = NO;
  [row addSubview:content];
  [NSLayoutConstraint activateConstraints:@[
    [content.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
    [content.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
    [content.topAnchor constraintEqualToAnchor:row.topAnchor],
    [content.bottomAnchor constraintEqualToAnchor:row.bottomAnchor]
  ]];

  [self updateSelectableRow:row selected:selected];
  return row;
}

- (void)updateSelectableRow:(UIButton *)row selected:(BOOL)selected {
  UILabel *label = [row viewWithTag:2001];
  UILabel *check = [row viewWithTag:2002];
  if (selected) {
    row.backgroundColor = [self colorWithHex:0xEAF2FF alpha:1.0];
    row.layer.borderColor = [self colorWithHex:0x3B82F6 alpha:1.0].CGColor;
    row.layer.borderWidth = 1.0;
    label.textColor = [self colorWithHex:0x1D4ED8 alpha:1.0];
    check.textColor = [self colorWithHex:0x1D4ED8 alpha:1.0];
    check.hidden = NO;
  } else {
    row.backgroundColor = [UIColor whiteColor];
    row.layer.borderWidth = 0.0;
    label.textColor = [self colorWithHex:0x111827 alpha:1.0];
    check.hidden = YES;
  }
}

- (void)presentSelectionPanelWithTitle:(NSString *)title
                              subtitle:(NSString *)subtitle
                               options:(NSArray<NSString *> *)options
                          currentIndex:(NSInteger)currentIndex
                             onConfirm:(CPCameraSelectionApplyBlock)onConfirm {
  __block NSInteger selectedIndex = MAX(0, MIN(currentIndex, (NSInteger)options.count - 1));
  self.selectionApplyBlock = onConfirm;
  self.selectionSelectedIndex = selectedIndex;

  __weak typeof(self) weakSelf = self;
  [self presentCardPanelWithTitle:title subtitle:subtitle bodyBuilder:^(UIStackView *stackView) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (strongSelf == nil) {
      return;
    }

    NSMutableArray<UIButton *> *optionButtons = [NSMutableArray array];
    for (NSInteger idx = 0; idx < (NSInteger)options.count; idx++) {
      UIButton *row = [strongSelf createSelectableRowWithTitle:options[idx] selected:(idx == selectedIndex)];
      row.tag = (NSInteger)(3000 + idx);
      [row addTarget:strongSelf action:@selector(onSelectionRowTapped:) forControlEvents:UIControlEventTouchUpInside];
      [optionButtons addObject:row];
      [stackView addArrangedSubview:row];
    }

    strongSelf.selectionOptionButtons = optionButtons;

    UIStackView *actions = [[UIStackView alloc] init];
    actions.axis = UILayoutConstraintAxisHorizontal;
    actions.spacing = 8.0;
    actions.distribution = UIStackViewDistributionFillEqually;

    UIButton *cancel = [strongSelf createPanelActionButtonWithTitle:@"取消" backgroundHex:0xE5E7EB textHex:0x374151];
    [cancel addTarget:strongSelf action:@selector(onSelectionCancelTapped) forControlEvents:UIControlEventTouchUpInside];
    [actions addArrangedSubview:cancel];

    UIButton *confirm = [strongSelf createPanelActionButtonWithTitle:@"确定" backgroundHex:0x111827 textHex:0xFFFFFF];
    [confirm addTarget:strongSelf action:@selector(onSelectionConfirmTapped) forControlEvents:UIControlEventTouchUpInside];
    [actions addArrangedSubview:confirm];

    [stackView addArrangedSubview:actions];
  }];
}

- (void)onSelectionRowTapped:(UIButton *)sender {
  NSInteger selectedIndex = sender.tag - 3000;
  if (selectedIndex < 0) {
    return;
  }

  NSArray<UIButton *> *buttons = self.selectionOptionButtons;
  if (buttons == nil) {
    return;
  }

  for (NSInteger idx = 0; idx < (NSInteger)buttons.count; idx++) {
    [self updateSelectableRow:buttons[idx] selected:(idx == selectedIndex)];
  }
  self.selectionSelectedIndex = selectedIndex;
}

- (void)onSelectionCancelTapped {
  [self dismissSettingsPanel];
}

- (void)onSelectionConfirmTapped {
  NSInteger selectedIndex = self.selectionSelectedIndex;
  CPCameraSelectionApplyBlock applyBlock = self.selectionApplyBlock;
  [self dismissSettingsPanel];
  if (applyBlock != nil) {
    applyBlock(selectedIndex);
  }
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
      [self dismissSettingsPanel];
        [self.settingsButton removeFromSuperview];
        self.settingsButton = nil;
        [self.cameraRenderController.view removeFromSuperview];
        [self.cameraRenderController removeFromParentViewController];
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
    [self.cameraRenderController.view setHidden:YES];
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
  CDVPluginResult *pluginResult;

  if (self.cameraRenderController != NULL) {
    self.onPictureTakenHandlerId = command.callbackId;

    CGFloat width = (CGFloat)[command.arguments[0] floatValue];
    CGFloat height = (CGFloat)[command.arguments[1] floatValue];
    CGFloat quality = (CGFloat)[command.arguments[2] floatValue] / 100.0f;

    [self invokeTakePicture:width withHeight:height withQuality:quality];
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
            NSString *base64Image = [self getBase64Image:image.CGImage withQuality:quality];
            NSMutableArray *params = [[NSMutableArray alloc] init];
            [params addObject:base64Image];
            CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:params];
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

    CDVPluginResult *pluginResult;

    if (self.sessionManager == nil) {
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Session not started"];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
        return;
    }

    if (command.arguments.count > 1) {
        CGFloat width = (CGFloat)[command.arguments[0] floatValue];
        CGFloat height = (CGFloat)[command.arguments[1] floatValue];

      self.previewContainerFrame = CGRectMake(0, 0, width, height);
      self.cameraRenderController.view.frame = self.previewContainerFrame;
        [self applyCaptureRatio:self.desiredCaptureRatio];

        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    } else {
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Invalid number of parameters"];
    }

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

- (double)radiansFromUIImageOrientation:(UIImageOrientation)orientation {
  double radians;

  switch ([[UIApplication sharedApplication] statusBarOrientation]) {
    case UIDeviceOrientationPortrait:
      radians = M_PI_2;
      break;
    case UIDeviceOrientationLandscapeLeft:
      radians = 0.f;
      break;
    case UIDeviceOrientationLandscapeRight:
      radians = M_PI;
      break;
    case UIDeviceOrientationPortraitUpsideDown:
      radians = -M_PI_2;
      break;
  }

  return radians;
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

- (void) invokeTakePicture {
  [self invokeTakePicture:0.0 withHeight:0.0 withQuality:0.85];
}

- (void) invokeTakePictureOnFocus {
    // the sessionManager will call onFocus, as soon as the camera is done with focussing.
  [self.sessionManager takePictureOnFocus];
}

- (void) capturePictureNow:(CGFloat) width withHeight:(CGFloat) height withQuality:(CGFloat) quality{
    AVCaptureConnection *connection = [self.sessionManager.stillImageOutput connectionWithMediaType:AVMediaTypeVideo];
    [self.sessionManager.stillImageOutput captureStillImageAsynchronouslyFromConnection:connection completionHandler:^(CMSampleBufferRef sampleBuffer, NSError *error) {

      NSLog(@"Done creating still image");

      if (error) {
        NSLog(@"%@", error);
      } else {

        NSData *imageData = [AVCaptureStillImageOutput jpegStillImageNSDataRepresentation:sampleBuffer];
        UIImage *capturedImage  = [[UIImage alloc] initWithData:imageData];

        CIImage *capturedCImage;
        //image resize

        if(width > 0 && height > 0){
          CGFloat scaleHeight = width/capturedImage.size.height;
          CGFloat scaleWidth = height/capturedImage.size.width;
          CGFloat scale = scaleHeight > scaleWidth ? scaleWidth : scaleHeight;

          CIFilter *resizeFilter = [CIFilter filterWithName:@"CILanczosScaleTransform"];
          [resizeFilter setValue:[[CIImage alloc] initWithCGImage:[capturedImage CGImage]] forKey:kCIInputImageKey];
          [resizeFilter setValue:[NSNumber numberWithFloat:1.0f] forKey:@"inputAspectRatio"];
          [resizeFilter setValue:[NSNumber numberWithFloat:scale] forKey:@"inputScale"];
          capturedCImage = [resizeFilter outputImage];
        }else{
          capturedCImage = [[CIImage alloc] initWithCGImage:[capturedImage CGImage]];
        }

        CIImage *imageToFilter;
        CIImage *finalCImage;

        //fix front mirroring
        if (self.sessionManager.defaultCamera == AVCaptureDevicePositionFront) {
          CGAffineTransform matrix = CGAffineTransformTranslate(CGAffineTransformMakeScale(1, -1), 0, capturedCImage.extent.size.height);
          imageToFilter = [capturedCImage imageByApplyingTransform:matrix];
        } else {
          imageToFilter = capturedCImage;
        }

        CIFilter *filter = [self.sessionManager ciFilter];
        if (filter != nil) {
          [self.sessionManager.filterLock lock];
          [filter setValue:imageToFilter forKey:kCIInputImageKey];
          finalCImage = [filter outputImage];
          [self.sessionManager.filterLock unlock];
        } else {
          finalCImage = imageToFilter;
        }

        CGImageRef finalImage = [self.cameraRenderController.ciContext createCGImage:finalCImage fromRect:finalCImage.extent];
        UIImage *resultImage = [UIImage imageWithCGImage:finalImage];

        double radians = [self radiansFromUIImageOrientation:resultImage.imageOrientation];
        CGImageRef resultFinalImage = [self CGImageRotated:finalImage withRadians:radians];

        CGImageRelease(finalImage); // release CGImageRef to remove memory leaks

        CDVPluginResult *pluginResult;
        if (self.storeToFile) {
          NSData *data = UIImageJPEGRepresentation([UIImage imageWithCGImage:resultFinalImage], (CGFloat) quality);
          NSString* filePath = [self getTempFilePath:@"jpg"];
          NSError *err;

          if (![data writeToFile:filePath options:NSAtomicWrite error:&err]) {
            pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_IO_EXCEPTION messageAsString:[err localizedDescription]];
          }
          else {
            pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:[[NSURL fileURLWithPath:filePath] absoluteString]];
          }
        } else {
          NSMutableArray *params = [[NSMutableArray alloc] init];
          NSString *base64Image = [self getBase64Image:resultFinalImage withQuality:quality];
          [params addObject:base64Image];
          pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:params];
        }

        CGImageRelease(resultFinalImage); // release CGImageRef to remove memory leaks

        [pluginResult setKeepCallbackAsBool:self.cameraRenderController.tapToTakePicture];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:self.onPictureTakenHandlerId];
      }
    }];
}

- (void) invokeTakePicture:(CGFloat) width withHeight:(CGFloat) height withQuality:(CGFloat) quality{
  if (self.captureTimerSeconds <= 0.0) {
    [self capturePictureNow:width withHeight:height withQuality:quality];
    return;
  }

  __weak typeof(self) weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.captureTimerSeconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (strongSelf == nil || strongSelf.sessionManager == nil || strongSelf.cameraRenderController == nil) {
      return;
    }
    [strongSelf capturePictureNow:width withHeight:height withQuality:quality];
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
