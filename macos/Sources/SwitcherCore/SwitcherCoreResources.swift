import Foundation

/// Resolves SwiftPM resources from their standard location inside a packaged
/// macOS application before falling back to SwiftPM's build-tree accessor.
///
/// SwiftPM generates `Bundle.module` with a lookup next to `Bundle.main.bundleURL`.
/// Our hand-built `.app` correctly stores resources in `Contents/Resources`, so
/// relying on the generated accessor made release builds accidentally depend on
/// the developer's local `.build` directory and crash on end-user Macs.
enum SwitcherCoreResources {
    static let bundle: Bundle = packagedBundle(in: Bundle.main.resourceURL) ?? .module

    static func packagedBundle(in resourceDirectory: URL?) -> Bundle? {
        guard let resourceDirectory else { return nil }
        for name in ["TypeFlow_SwitcherCore.bundle", "LocalSwitcher_SwitcherCore.bundle"] {
            let candidate = resourceDirectory.appendingPathComponent(name, isDirectory: true)
            if let bundle = Bundle(url: candidate) {
                return bundle
            }
        }
        return nil
    }
}
