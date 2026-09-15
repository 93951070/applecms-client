#import "AirplayRoutePickerFactory.h"
#import "AirplayRoutePickerView.h"

@implementation AirplayRoutePickerFactory {
  NSObject<FlutterBinaryMessenger> *_messenger;
}

- (instancetype)initWithMessenger:(NSObject<FlutterBinaryMessenger> *)messenger {
  self = [super init];
  if (self) {
    _messenger = messenger;
  }
  return self;
}

- (NSObject<FlutterPlatformView> *)createWithFrame:(CGRect)frame
                                    viewIdentifier:(int64_t)viewId
                                         arguments:(id _Nullable)args {
  return [[AirplayRoutePickerView alloc] initWithFrame:frame
                                            viewId:viewId
                                         arguments:args
                                         messenger:_messenger];
}

- (NSObject<FlutterMessageCodec> *)createArgsCodec {
  return [FlutterStandardMessageCodec sharedInstance];
}

@end
