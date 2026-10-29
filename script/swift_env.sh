# 只装了命令行工具（无 Xcode）时：SDK 27 的 SwiftUI 宏插件缺失，改用 26.5 SDK；
# 测试框架 Swift Testing 在 CLT 的 Developer/Frameworks 下，需显式给出路径。
CLT=/Library/Developer/CommandLineTools
if [[ -z "${SDKROOT:-}" && ! -d /Applications/Xcode.app && -d "$CLT/SDKs/MacOSX26.5.sdk" ]]; then
  export SDKROOT="$CLT/SDKs/MacOSX26.5.sdk"
fi
SWIFT_TEST_FLAGS=(--build-system native
  -Xswiftc -F -Xswiftc "$CLT/Library/Developer/Frameworks"
  -Xswiftc -plugin-path -Xswiftc "$CLT/usr/lib/swift/host/plugins/testing"
  -Xlinker -rpath -Xlinker "$CLT/Library/Developer/Frameworks"
  -Xlinker -F -Xlinker "$CLT/Library/Developer/Frameworks")
