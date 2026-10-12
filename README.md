# FullScreenBackUniversal (返回最新版)

通用全屏返回 dylib：任意 App 全屏任意位置右滑返回 + 连续两次边缘滑动回桌面。

- 纯 Objective-C，无 substrate / Logos 依赖
- 最低 iOS 15.0，arm64
- 震动默认开启，无设置项
- 编译：Xcode clang（GitHub Actions）
- 用法：TrollFools 注入 dylib + plist（Filter Bundles = *）
