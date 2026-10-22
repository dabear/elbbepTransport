import Foundation

private final class LupedBundleFinder {}

extension Bundle {
    /// LupedKit's resource bundle.
    ///
    /// SwiftPM's generated `Bundle.module` stops the app when the resource bundle
    /// wasn't embedded, as happens when LupedKit is linked into a host plugin
    /// framework that doesn't copy it. This looks in the same places and falls
    /// back to the bundle containing LupedKit's code, so strings show untranslated
    /// instead of crashing.
    static let lupedKit: Bundle = {
        let name = "elbbepTransport_LupedKit.bundle"
        let codeBundle = Bundle(for: LupedBundleFinder.self)
        let candidates = [Bundle.main.resourceURL, codeBundle.resourceURL, Bundle.main.bundleURL, codeBundle.bundleURL]
        for case let url? in candidates {
            if let bundle = Bundle(url: url.appendingPathComponent(name)) {
                return bundle
            }
        }
        return codeBundle
    }()
}
