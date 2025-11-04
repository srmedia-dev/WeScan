Pod::Spec.new do |s|
  s.name             = 'WeScan'
  s.version          = '1.7.0-local'
  s.summary          = 'Document Scanning Made Easy for iOS'
  s.description      = <<-DESC
WeScan makes it easy to add scanning functionalities to your iOS app!
It's modelled after UIImagePickerController, which makes it a breeze to use.
  DESC
  s.homepage         = 'https://github.com/WeTransferArchive/WeScan'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.authors          = {
    'Boris Emorine' => 'boris@wetransfer.com',
    'Antoine van der Lee' => 'antoine@wetransfer.com'
  }
  s.source           = { :path => '.' }

  s.platform     = :ios, '10.0'
  s.swift_version = '5.0'
  s.swift_versions = ['5.0']

  s.source_files = 'Sources/WeScan/**/*.{swift}'
  s.resources    = [
    'Sources/WeScan/Resources/Localisation/**/*.strings',
    'Sources/WeScan/Resources/Assets/**/*.{png}',
    'Sources/WeScan/Resources/Assets/**/*.xcassets'
  ]

  s.frameworks = 'UIKit', 'AVFoundation'
end
