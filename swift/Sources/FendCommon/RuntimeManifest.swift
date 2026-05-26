// Dev placeholder. Release builds overwrite this file via
// scripts/write-runtime-manifest.sh during release.yml, baking in the
// real version, bundle name, SHA256, and URL.
//
// A dev build (empty SHA / version == "dev") refuses to bootstrap from
// a network URL — there is no published bundle that matches a local
// working copy, so the right behaviour is to point the developer at
// `fend setup --build-from-source`.

public enum RuntimeManifest {
    public static let runtimeVersion: String = "dev"
    public static let bundleName: String = ""
    public static let bundleSHA256: String = ""
    public static let bundleURL: String = ""
    public static let schemaVersion: Int = 1

    /// True if this binary was built without a release-time runtime pin
    /// (i.e. running from a `swift run` / `swift build` checkout).
    public static var isDevBuild: Bool {
        return runtimeVersion == "dev" || bundleSHA256.isEmpty
    }
}
