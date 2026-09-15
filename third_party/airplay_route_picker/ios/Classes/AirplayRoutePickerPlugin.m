#import "AirplayRoutePickerPlugin.h"
#import "AirplayRoutePickerFactory.h"

@implementation AirplayRoutePickerPlugin

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  AirplayRoutePickerFactory *factory =
      [[AirplayRoutePickerFactory alloc] initWithMessenger:[registrar messenger]];
  [registrar registerViewFactory:factory withId:@"airplay_route_picker_view"];
}

@end
