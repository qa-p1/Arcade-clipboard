#!/usr/bin/env ruby
# Wire the checked-in iOS host/extension sources into a Flutter-generated runner.
# Run from any directory after `flutter create --platforms=ios .` in apps/flutter_app.

require 'fileutils'
require 'pathname'
require 'xcodeproj'

REPO_ROOT = Pathname.new(__dir__).parent.expand_path
IOS_ROOT = REPO_ROOT.join('apps/flutter_app/ios')
PROJECT_PATH = IOS_ROOT.join('Runner.xcodeproj')
APP_DELEGATE = IOS_ROOT.join('Runner/AppDelegate.swift')
APP_INFO_PLIST = IOS_ROOT.join('Runner/Info.plist')
DEFAULT_BUNDLE_ID = 'dev.arcade.clipboard'
DEFAULT_APP_GROUP = 'group.dev.arcade.clipboard'
# Flutter's Swift packages (including integration_test) require iOS 15.
MINIMUM_IOS = '15.0'
IOS_DEVICE_ARCHIVE = '$(PROJECT_DIR)/../../../target/$(ARCADE_RUST_IOS_TARGET)/release/libarcade_core.a'

def abort_setup(message)
  warn "iOS setup: #{message}"
  exit 1
end

def backup_once(path)
  backup = Pathname.new("#{path}.arcade-ios.bak")
  FileUtils.cp(path, backup) unless backup.exist?
  backup
end

def find_or_create_group(parent, name, path)
  parent.groups.find { |group| group.name == name } || parent.new_group(name, path)
end

def source_reference(group, basename)
  group.files.find { |file| file.path == basename } || group.new_file(basename)
end

def add_sources(target, refs)
  return if refs.empty?

  target.add_file_references(refs)
end

def set_configurations(target, values)
  target.build_configurations.each do |configuration|
    values.each { |key, value| configuration.build_settings[key] = value }
  end
end

def enable_app_groups_capability(project, target)
  attributes = project.root_object.attributes
  target_attributes = attributes['TargetAttributes'] ||= {}
  target_metadata = target_attributes[target.uuid] ||= {}
  target_metadata['ProvisioningStyle'] ||= 'Automatic'
  capabilities = target_metadata['SystemCapabilities'] ||= {}
  capabilities['com.apple.ApplicationGroups'] = { 'enabled' => 1 }
end

def add_force_load(settings)
  current = settings['OTHER_LDFLAGS']
  flags = current.is_a?(Array) ? current.dup : (current.nil? ? ['$(inherited)'] : [current])
  force_load = "-force_load \"#{IOS_DEVICE_ARCHIVE}\""
  flags << force_load unless flags.join(' ').include?(force_load)
  security_linked = flags.join(' ').include?('-framework Security')
  flags.concat(['-framework', 'Security']) unless security_linked
  settings['OTHER_LDFLAGS'] = flags
end

def add_embed_extension(host, extension)
  already_depends = host.dependencies.any? { |dependency| dependency.target == extension }
  host.add_dependency(extension) unless already_depends

  phase = host.copy_files_build_phases.find { |item| item.name == 'Embed App Extensions' }
  phase ||= host.new_copy_files_build_phase('Embed App Extensions')
  phase.dst_subfolder_spec = '13' # PlugIns
  phase.add_file_reference(extension.product_reference, true)
  build_file = phase.files.find { |item| item.file_ref == extension.product_reference }
  build_file.settings ||= {}
  build_file.settings['ATTRIBUTES'] = (Array(build_file.settings['ATTRIBUTES']) + ['CodeSignOnCopy']).uniq
end

def find_or_create_extension(project, name, deployment_target)
  existing = project.targets.find { |target| target.name == name }
  if existing
    abort_setup("target #{name.inspect} already exists but is not an app extension") unless existing.symbol_type == :app_extension
    return existing
  end

  project.new_target(:app_extension, name, :ios, deployment_target)
end

def patch_app_delegate(source)
  registration = 'MobileMethodChannel.register('
  return source if source.include?(registration)
  if source.include?('didInitializeImplicitFlutterEngine')
    return source.sub('GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)',
      "GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)\n    MobileMethodChannel.register(with: engineBridge.applicationRegistrar.messenger())")
  end

  return source if source.include?(registration)

  unless source.match?(/^[ \t]*GeneratedPluginRegistrant\.register\(with: self\)[ \t]*$/)
    abort_setup('could not find the standard GeneratedPluginRegistrant line in Runner/AppDelegate.swift; no project files were changed')
  end

  pattern = /^(?<indent>[ \t]*)return[ \t]+super\.application\s*\(\s*application\s*,\s*didFinishLaunchingWithOptions:\s*launchOptions\s*\)/
  matches = source.scan(pattern)
  abort_setup('could not find the standard super.application launch call in Runner/AppDelegate.swift; no project files were changed') unless matches.length == 1

  source.sub(pattern) do
    indent = Regexp.last_match[:indent]
    [
      "#{indent}let didFinishLaunching = super.application(",
      "#{indent}  application,",
      "#{indent}  didFinishLaunchingWithOptions: launchOptions",
      "#{indent})",
      "#{indent}guard didFinishLaunching else { return false }",
      "#{indent}guard let flutterController = window?.rootViewController as? FlutterViewController else {",
      "#{indent}  fatalError(\"Arcade Clipboard requires a FlutterViewController root before registering its mobile channel.\")",
      "#{indent}}",
      "#{indent}MobileMethodChannel.register(with: flutterController.binaryMessenger)",
      "#{indent}return true",
    ].join("\n")
  end
end

def patch_local_network_description(source)
  return source if source.include?('<key>NSLocalNetworkUsageDescription</key>')

  index = source.rindex('</dict>')
  abort_setup('could not find the root dictionary in Runner/Info.plist; no project files were changed') unless index

  entry = <<~PLIST
    \t<key>NSLocalNetworkUsageDescription</key>
    \t<string>Arcade Clipboard connects directly to your other devices on your local network.</string>
  PLIST
  source.dup.insert(index, entry)
end

unless PROJECT_PATH.directory? && APP_DELEGATE.file? && APP_INFO_PLIST.file?
  abort_setup("Flutter iOS runner is missing. Generate it first with `cd apps/flutter_app && flutter create --no-pub --platforms=ios --org dev.arcade --project-name clipboard .`.")
end

bundle_id = ENV.fetch('IOS_BUNDLE_ID', DEFAULT_BUNDLE_ID)
app_group = DEFAULT_APP_GROUP
abort_setup('IOS_BUNDLE_ID must be a reverse-DNS identifier containing only letters, digits, and dots') unless bundle_id.match?(/\A[A-Za-z0-9]+(?:[.-][A-Za-z0-9]+)+\z/)

app_delegate_original = APP_DELEGATE.read
app_delegate_updated = patch_app_delegate(app_delegate_original)
app_info_original = APP_INFO_PLIST.read
app_info_updated = patch_local_network_description(app_info_original)

project = Xcodeproj::Project.open(PROJECT_PATH.to_s)
runner = project.targets.find { |target| target.name == 'Runner' && target.symbol_type == :application }
abort_setup('Runner.xcodeproj has no application target named Runner') unless runner

deployment_targets = runner.build_configurations.map do |configuration|
  configuration.build_settings['IPHONEOS_DEPLOYMENT_TARGET']
end.compact.reject(&:empty?)
deployment_target = deployment_targets.max_by { |version| version.split('.').map(&:to_i) } || MINIMUM_IOS
deployment_target = [deployment_target, MINIMUM_IOS].max_by { |version| version.split('.').map(&:to_i) }
# The app, its extensions and every Swift package must agree on one floor.
(project.build_configurations + runner.build_configurations).each do |configuration|
  configuration.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = deployment_target
end

ios_group = find_or_create_group(project.main_group, 'Arcade iOS Integration', '../../../platform/ios')
runner_group = find_or_create_group(ios_group, 'Runner', 'Runner')
shared_group = find_or_create_group(ios_group, 'Shared', 'Shared')
share_group = find_or_create_group(ios_group, 'ShareExtension', 'ShareExtension')
keyboard_group = find_or_create_group(ios_group, 'KeyboardExtension', 'KeyboardExtension')
configuration_group = find_or_create_group(ios_group, 'Configuration', 'Configuration')

store_ref = source_reference(shared_group, 'MobileSharedStore.swift')
channel_ref = source_reference(runner_group, 'MobileMethodChannel.swift')
share_ref = source_reference(share_group, 'ShareViewController.swift')
keyboard_ref = source_reference(keyboard_group, 'MeshKeyboardViewController.swift')
source_reference(share_group, 'Info.plist')
source_reference(keyboard_group, 'Info.plist')
source_reference(configuration_group, 'Runner.entitlements')
source_reference(configuration_group, 'ShareExtension.entitlements')
source_reference(configuration_group, 'KeyboardExtension.entitlements')

share_name = 'ArcadeShareExtension'
keyboard_name = 'ArcadeKeyboardExtension'
share = find_or_create_extension(project, share_name, deployment_target)
keyboard = find_or_create_extension(project, keyboard_name, deployment_target)

add_sources(runner, [store_ref, channel_ref])
add_sources(share, [store_ref, share_ref])
add_sources(keyboard, [store_ref, keyboard_ref])

set_configurations(runner, {
  # FFI resolves exported Rust symbols at runtime, outside the linker's call graph.
  'DEAD_CODE_STRIPPING' => 'NO',
  'STRIP_INSTALLED_PRODUCT' => 'NO',
  'STRIP_STYLE' => 'non-global',
  'PRODUCT_BUNDLE_IDENTIFIER' => bundle_id,
  'CODE_SIGN_ENTITLEMENTS' => '../../../platform/ios/Configuration/Runner.entitlements',
})
enable_app_groups_capability(project, runner)
runner.build_configurations.each do |configuration|
  settings = configuration.build_settings
  settings['ARCADE_RUST_IOS_TARGET[sdk=iphoneos*]'] = 'aarch64-apple-ios'
  settings['ARCADE_RUST_IOS_TARGET[sdk=iphonesimulator*][arch=arm64]'] = 'aarch64-apple-ios-sim'
  settings['ARCADE_RUST_IOS_TARGET[sdk=iphonesimulator*][arch=x86_64]'] = 'x86_64-apple-ios'
  add_force_load(settings)
end

[
  [share, share_name, 'ShareExtension', 'ShareExtension.entitlements'],
  [keyboard, keyboard_name, 'KeyboardExtension', 'KeyboardExtension.entitlements'],
].each do |target, target_name, plist_name, entitlements_name|
  # Extension versions must match the containing app, including CLI overrides.
  target.build_configurations.each do |configuration|
    runner_configuration = runner.build_configurations.find { |item| item.name == configuration.name }
    configuration.base_configuration_reference = runner_configuration.base_configuration_reference if runner_configuration
  end
  set_configurations(target, {
    'APPLICATION_EXTENSION_API_ONLY' => 'YES',
    'CODE_SIGN_ENTITLEMENTS' => "../../../platform/ios/Configuration/#{entitlements_name}",
    'CODE_SIGN_STYLE' => 'Automatic',
    'CURRENT_PROJECT_VERSION' => '$(FLUTTER_BUILD_NUMBER)',
    'MARKETING_VERSION' => '$(FLUTTER_BUILD_NAME)',
    'GENERATE_INFOPLIST_FILE' => 'NO',
    'INFOPLIST_FILE' => "../../../platform/ios/#{plist_name}/Info.plist",
    'IPHONEOS_DEPLOYMENT_TARGET' => deployment_target,
    'LD_RUNPATH_SEARCH_PATHS' => '$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks',
    'PRODUCT_BUNDLE_IDENTIFIER' => "#{bundle_id}.#{target_name == share_name ? 'share' : 'keyboard'}",
    'PRODUCT_NAME' => '$(TARGET_NAME)',
    'SKIP_INSTALL' => 'YES',
    'SUPPORTED_PLATFORMS' => 'iphoneos iphonesimulator',
    'SWIFT_VERSION' => '5.0',
    'TARGETED_DEVICE_FAMILY' => '1,2',
  })
  enable_app_groups_capability(project, target)
end

add_embed_extension(runner, share)
add_embed_extension(runner, keyboard)

if app_delegate_updated != app_delegate_original
  backup_once(APP_DELEGATE)
  APP_DELEGATE.write(app_delegate_updated)
end
if app_info_updated != app_info_original
  backup_once(APP_INFO_PLIST)
  APP_INFO_PLIST.write(app_info_updated)
end

project_backup = Pathname.new("#{PROJECT_PATH.join('project.pbxproj')}.arcade-ios.bak")
backup_once(PROJECT_PATH.join('project.pbxproj'))
project.save

puts 'iOS integration wired into apps/flutter_app/ios/Runner.xcodeproj.'
puts "Host bundle ID: #{bundle_id}"
puts "Share extension: #{bundle_id}.share"
puts "Keyboard extension: #{bundle_id}.keyboard"
puts "App Group: #{app_group}"
puts "Project backup: #{project_backup}"
puts "AppDelegate backup: #{APP_DELEGATE}.arcade-ios.bak" if app_delegate_updated != app_delegate_original
puts "Runner Info.plist backup: #{APP_INFO_PLIST}.arcade-ios.bak" if app_info_updated != app_info_original
puts 'Select the same signing team for all targets and register the App Group for that team.'
puts 'The host uses authenticated direct connections and local mesh discovery.'
