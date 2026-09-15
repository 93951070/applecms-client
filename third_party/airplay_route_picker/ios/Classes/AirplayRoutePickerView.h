#import <Flutter/Flutter.h>

/// 承载 iOS 原生 `AVRoutePickerView` 的平台视图。
///
/// 点击即由系统弹出 AirPlay 设备列表；弹出/收起会通过方法通道回调 Dart。
@interface AirplayRoutePickerView : NSObject <FlutterPlatformView>

- (instancetype)initWithFrame:(CGRect)frame
                       viewId:(int64_t)viewId
                    arguments:(id _Nullable)args
                    messenger:(NSObject<FlutterBinaryMessenger> *)messenger;

@end
