Pod::Spec.new do |s|
  s.name = 'arcade_desktop_bridge'
  s.version = '0.1.0'
  s.summary = 'Native clipboard, focus and lifecycle integration.'
  s.description = 'Desktop clipboard formats, explicit paste actions, menu bar and launch at login.'
  s.homepage = 'https://github.com/arcade-clipboard/arcade-clipboard'
  s.license = { :type => 'MIT' }
  s.author = { 'Arcade Clipboard' => 'dev@arcade.invalid' }
  s.source = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'FlutterMacOS'
  s.platform = :osx, '10.15'
  s.swift_version = '5.0'
  s.frameworks = 'AppKit', 'ServiceManagement'
end
