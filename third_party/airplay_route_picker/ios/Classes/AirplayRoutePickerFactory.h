#import <Flutter/Flutter.h>

/// 创建原生 `AVRoutePickerView` 平台视图。仅实现投屏选择器，不涉及播放器。
@interface AirplayRoutePickerFactory : NSObject <FlutterPlatformViewFactory>

- (instancetype)initWithMessenger:(NSObject<FlutterBinaryMessenger> *)messenger;

@end
