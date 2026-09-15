Pod::Spec.new do |s|
  s.name             = 'airplay_route_picker'
  s.version          = '1.0.0'
  s.summary          = 'Native AVRoutePickerView button for Flutter apps (iOS only).'
  s.description      = <<-DESC
内嵌 iOS 原生 AVRoutePickerView，供 App 直接唤起系统 AirPlay 投屏设备列表。
                       DESC
  s.homepage         = 'https://github.com/93951070/applecms-client'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'echotv' => 'noreply@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '12.0'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.frameworks = 'AVKit', 'MediaPlayer'
end
