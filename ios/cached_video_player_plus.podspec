#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint cached_video_player_plus.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'cached_video_player_plus'
  s.version          = '0.0.1'
  s.summary          = 'Advanced Video Player with Caching'
  s.description      = <<-DESC
A Flutter plugin for playing back video with advanced caching capabilities using AVAssetResourceLoader on iOS.
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'OutdatedGuy' => 'email@example.com' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
