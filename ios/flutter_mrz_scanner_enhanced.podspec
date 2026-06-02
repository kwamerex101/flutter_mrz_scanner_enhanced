#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
#
Pod::Spec.new do |s|
  s.name             = 'flutter_mrz_scanner_enhanced'
  s.version          = '0.0.1'
  s.summary          = 'Flutter plugin for scanning MRZ codes from ID documents.'
  s.description      = <<-DESC
A Flutter plugin for scanning MRZ (Machine Readable Zone) codes from identity documents, passports, and travel documents.
                       DESC
  s.homepage         = 'https://github.com/ELMEHDAOUIAhmed/flutter_mrz_scanner_enhanced'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'ELMEHDAOUIAhmed' => 'email@example.com' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.resources = ['Assets/TraineedDataBundle.bundle']
  s.dependency 'Flutter'
  s.dependency 'SwiftyTesseract', '~> 3.1.3'
  # Deployment target raised from 12.0 to 13.0 to match the Flutter 3.41+ floor.
  s.platform = :ios, '13.0'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  # SwiftyTesseract 3.1.x's libtesseract.xcframework ships no ios-arm64-simulator slice.
  # Propagate the arm64-sim exclusion to consumer apps so they don't have to patch their
  # own Podfile / xcconfig on Apple Silicon Macs. Physical-device builds (iphoneos) are
  # unaffected and continue to use the native arm64 slice.
  s.user_target_xcconfig = { 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'arm64' }
  s.swift_version = '5.0'
end 