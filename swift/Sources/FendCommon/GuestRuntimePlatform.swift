/// Linux userspace architecture expected inside the guest VM.
public enum GuestRuntimePlatform: String, Equatable {
    case linuxARM64 = "linux-arm64"
    case linuxX64 = "linux-x64"

    public static var current: GuestRuntimePlatform {
        #if arch(arm64)
        return .linuxARM64
        #elseif arch(x86_64)
        return .linuxX64
        #else
        return .linuxARM64
        #endif
    }

    var nodeArchivePlatform: String {
        switch self {
        case .linuxARM64: return "linux-arm64"
        case .linuxX64: return "linux-x64"
        }
    }

    var bunArchivePlatform: String {
        switch self {
        case .linuxARM64: return "linux-aarch64"
        case .linuxX64: return "linux-x64"
        }
    }

    var usesLegacyToolDirectoryName: Bool {
        self == .linuxARM64
    }

    func nodeArchiveName(version: String) -> String {
        "node-v\(version)-\(nodeArchivePlatform)"
    }

    func bunArchiveName() -> String {
        "bun-\(bunArchivePlatform)"
    }
}
