import Foundation

/// SwiftPM 生成的 `Bundle.module` 访问器在找不到资源包时，会回退到编译期写死的
/// `.build/...` 绝对路径，并在两者都不存在时 `fatalError`。
///
/// 发布包（Release）绝不能引用它，原因有二：
///   1. 它会把开发机的绝对路径写进安装包，泄露工程目录结构；
///   2. 一旦主包缺少某个资源，开发机能读到 `.build` 所以"测试正常"，
///      而用户机器上会直接崩溃。
///
/// 因此这里只在 Debug 构建（本地开发与 `swift test`）中暴露 `Bundle.module`。
/// Release 构建下该引用根本不会被编译，生成的访问器也就不会进入二进制。
///
/// 发布包中请使用 `Bundle.main`（资源由 `scripts/package-app.sh` 按
/// `config/bundle-resources.json` 放进 `Contents/Resources`）。
enum StacioPackageResources {
    static var moduleBundle: Bundle? {
        #if DEBUG
        return Bundle.module
        #else
        return nil
        #endif
    }
}
