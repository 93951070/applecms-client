#import "AirplayRoutePickerView.h"

#import <AVKit/AVKit.h>
#import <MediaPlayer/MediaPlayer.h>

@interface AirplayRoutePickerView () <AVRoutePickerViewDelegate>
@end

@implementation AirplayRoutePickerView {
  UIView *_pickerView;
  FlutterMethodChannel *_channel;
}

- (instancetype)initWithFrame:(CGRect)frame
                       viewId:(int64_t)viewId
                    arguments:(id _Nullable)args
                    messenger:(NSObject<FlutterBinaryMessenger> *)messenger {
  self = [super init];
  if (self) {
    NSDictionary *arguments = [args isKindOfClass:[NSDictionary class]] ? args : @{};
    _channel = [FlutterMethodChannel methodChannelWithName:
                    [NSString stringWithFormat:@"airplay_route_picker#%lld", viewId]
                                           binaryMessenger:messenger];

    CGSize size = frame.size;
    if (size.width <= 0 || size.height <= 0) {
      size = CGSizeMake(26.0, 26.0);
    }

    if (@available(iOS 11.0, *)) {
      AVRoutePickerView *picker = [[AVRoutePickerView alloc] initWithFrame:CGRectMake(0, 0, size.width, size.height)];
      picker.delegate = self;
      picker.backgroundColor = [UIColor clearColor];
      picker.tintColor = [self colorFromArguments:arguments[@"tintColor"] fallback:picker.tintColor];
      picker.activeTintColor =
          [self colorFromArguments:arguments[@"activeTintColor"] fallback:picker.activeTintColor];
      if (@available(iOS 13.0, *)) {
        picker.prioritizesVideoDevices = [arguments[@"prioritizesVideoDevices"] boolValue];
      }
      _pickerView = picker;
    } else {
      // iOS 11 以下退化为系统音量/输出选择按钮。
      MPVolumeView *volumeView = [[MPVolumeView alloc] initWithFrame:CGRectMake(0, 0, size.width, size.height)];
      volumeView.showsVolumeSlider = NO;
      volumeView.tintColor = [self colorFromArguments:arguments[@"tintColor"] fallback:volumeView.tintColor];
      _pickerView = volumeView;
    }
  }
  return self;
}

- (UIView *)view {
  return _pickerView;
}

- (void)dealloc {
  [_channel setMethodCallHandler:nil];
}

#pragma mark - 辅助

/// Dart 侧传 0.0~1.0 的颜色分量；缺失时沿用系统默认色。
- (UIColor *)colorFromArguments:(id)value fallback:(UIColor *)fallback {
  if (![value isKindOfClass:[NSDictionary class]]) {
    return fallback;
  }
  NSDictionary *map = value;
  NSNumber *red = map[@"red"];
  NSNumber *green = map[@"green"];
  NSNumber *blue = map[@"blue"];
  NSNumber *alpha = map[@"alpha"];
  if (red == nil || green == nil || blue == nil) {
    return fallback;
  }
  return [UIColor colorWithRed:red.doubleValue
                         green:green.doubleValue
                          blue:blue.doubleValue
                         alpha:alpha == nil ? 1.0 : alpha.doubleValue];
}

#pragma mark - AVRoutePickerViewDelegate

- (void)routePickerViewWillBeginPresentingRoutes:(AVRoutePickerView *)routePickerView {
  [_channel invokeMethod:@"onShowPickerView" arguments:nil];
}

- (void)routePickerViewDidEndPresentingRoutes:(AVRoutePickerView *)routePickerView {
  [_channel invokeMethod:@"onClosePickerView" arguments:nil];
}

@end
