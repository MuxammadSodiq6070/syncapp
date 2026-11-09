Pod::Spec.new do |s|
  s.name         = 'sync_core'
  s.version      = '1.0.0'
  s.summary      = 'Sync C++20 engine: network, E2EE, local database.'
  s.homepage     = 'https://example.invalid/sync'
  s.license      = { :type => 'Proprietary' }
  s.author       = 'Sync'
  s.source       = { :path => '.' }
  s.ios.deployment_target = '15.0'
  s.osx.deployment_target = '10.15'
  s.source_files = 'core/include/*.h', 'core/src/*.{h,cpp}',
                   'core/third_party/monocypher/*.{h,c}', 'core/third_party/sqlite/*.{h,c}',
                   'core/third_party/nlohmann/*.hpp',
                   'core/third_party/mbedtls/include/**/*.h',
                   'core/third_party/mbedtls/library/*.c'
  s.public_header_files = 'core/include/sync_core.h'
  s.static_framework = true
  s.pod_target_xcconfig = {
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++20',
    'GCC_PREPROCESSOR_DEFINITIONS' => 'SQLITE_THREADSAFE=2 SQLITE_OMIT_LOAD_EXTENSION SQLITE_DQS=0 MBEDTLS_USER_CONFIG_FILE="<mbedtls_user_config.h>"',
    'HEADER_SEARCH_PATHS' => '"${PODS_TARGET_SRCROOT}/core/include" "${PODS_TARGET_SRCROOT}/core/src" "${PODS_TARGET_SRCROOT}/core/third_party/mbedtls/include" "${PODS_TARGET_SRCROOT}/core/third_party/monocypher" "${PODS_TARGET_SRCROOT}/core/third_party/sqlite" "${PODS_TARGET_SRCROOT}/core/third_party/nlohmann"',
  }
  # Dart finds the symbols with DynamicLibrary.process(), so they must survive linking.
  s.user_target_xcconfig = {
    'OTHER_LDFLAGS' => '$(inherited) -force_load "${PODS_CONFIGURATION_BUILD_DIR}/sync_core/libsync_core.a"',
  }
end
