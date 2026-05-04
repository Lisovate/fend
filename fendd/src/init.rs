use crate::protocol::base64_decode;
use std::ffi::CString;

/// Initialize the guest environment (PID 1 duties).
pub fn initialize() {
    init_filesystems();
    set_hostname("fend");
    set_clock_from_cmdline();
    load_modules();
    mount_virtiofs();
    setup_networking();
    setup_environment();
}

fn init_filesystems() {
    mount("proc", "/proc", "proc");
    mount("sysfs", "/sys", "sysfs");
    mount("devtmpfs", "/dev", "devtmpfs");

    std::fs::create_dir_all("/dev/pts").ok();
    mount("devpts", "/dev/pts", "devpts");

    std::fs::create_dir_all("/tmp").ok();
}

fn mount(source: &str, target: &str, fstype: &str) {
    let src = CString::new(source).unwrap();
    let tgt = CString::new(target).unwrap();
    let fst = CString::new(fstype).unwrap();

    let ret = unsafe {
        libc::mount(
            src.as_ptr(),
            tgt.as_ptr(),
            fst.as_ptr(),
            0,
            std::ptr::null(),
        )
    };

    if ret == 0 {
        eprintln!("fendd: mounted {} ({})", target, fstype);
    } else {
        let err = std::io::Error::last_os_error();
        eprintln!("fendd: mount {} failed: {}", target, err);
    }
}

fn set_clock_from_cmdline() {
    let cmdline = match std::fs::read_to_string("/proc/cmdline") {
        Ok(s) => s,
        Err(_) => return,
    };

    for param in cmdline.split_whitespace() {
        if let Some(epoch_str) = param.strip_prefix("fend.epoch=") {
            if let Ok(epoch) = epoch_str.parse::<i64>() {
                let tv = libc::timeval {
                    tv_sec: epoch,
                    tv_usec: 0,
                };
                let ret = unsafe { libc::settimeofday(&tv, std::ptr::null()) };
                if ret == 0 {
                    eprintln!("fendd: clock set to epoch {}", epoch);
                } else {
                    eprintln!("fendd: settimeofday failed: {}", std::io::Error::last_os_error());
                }
            }
        }
    }
}

fn read_cwd_from_cmdline() -> Option<String> {
    let cmdline = std::fs::read_to_string("/proc/cmdline").ok()?;
    for param in cmdline.split_whitespace() {
        if let Some(b64) = param.strip_prefix("fend.cwd=") {
            if let Some(bytes) = base64_decode(b64) {
                return String::from_utf8(bytes).ok();
            }
        }
    }
    None
}

fn set_hostname(name: &str) {
    unsafe {
        libc::sethostname(name.as_ptr() as *const _, name.len());
    }
}

fn load_modules() {
    for name in &[
        "fuse",
        "virtiofs",
        "virtio_net",
        "vsock",
        "vmw_vsock_virtio_transport_common",
        "vmw_vsock_virtio_transport",
    ] {
        let path = format!("/lib/modules/{}.ko", name);
        if std::path::Path::new(&path).exists() {
            load_module(&path, name);
        }
    }
}

fn load_module(path: &str, name: &str) {
    use std::os::fd::AsRawFd;

    let file = match std::fs::File::open(path) {
        Ok(f) => f,
        Err(e) => {
            eprintln!("fendd: open {} failed: {}", path, e);
            return;
        }
    };

    let empty = CString::new("").unwrap();
    let ret = unsafe { libc::syscall(libc::SYS_finit_module, file.as_raw_fd(), empty.as_ptr(), 0) };

    if ret == 0 {
        eprintln!("fendd: loaded {}", name);
    } else {
        let err = std::io::Error::last_os_error();
        if err.raw_os_error() != Some(libc::EEXIST) {
            eprintln!("fendd: load {} failed: {}", name, err);
        }
    }
}

fn mount_virtiofs() {
    let workspace = read_cwd_from_cmdline().unwrap_or_else(|| "/workspace".to_string());
    std::fs::create_dir_all(&workspace).ok();
    mount("workspace", &workspace, "virtiofs");
    eprintln!("fendd: workspace at {}", workspace);

    // Make the project's .git/ read-only inside the sandbox so malicious code
    // running during `npm install` / `npm run dev` can't silently rewrite
    // commits or push a backdoor via the user's existing git credentials.
    let git_dir = format!("{}/.git", workspace);
    if std::path::Path::new(&git_dir).exists() {
        bind_mount_readonly(&git_dir);
    }

    std::fs::create_dir_all("/home/user/.npm").ok();
    mount("cache", "/home/user/.npm", "virtiofs");

    std::fs::create_dir_all("/opt/tools").ok();
    mount("tools", "/opt/tools", "virtiofs");
}

/// Bind-mount a path over itself read-only. Requires two mount() calls on Linux:
/// first MS_BIND, then MS_REMOUNT|MS_BIND|MS_RDONLY.
fn bind_mount_readonly(path: &str) {
    // Linux mount flag constants (from linux/mount.h).
    const MS_RDONLY: u64 = 1;
    const MS_REMOUNT: u64 = 32;
    const MS_BIND: u64 = 4096;

    let src = CString::new(path).unwrap();
    let tgt = src.clone();
    let none = CString::new("none").unwrap();

    let r1 = unsafe {
        libc::mount(
            src.as_ptr(),
            tgt.as_ptr(),
            none.as_ptr(),
            MS_BIND,
            std::ptr::null(),
        )
    };
    if r1 != 0 {
        eprintln!(
            "fendd: bind-mount {} failed: {}",
            path,
            std::io::Error::last_os_error()
        );
        return;
    }

    let r2 = unsafe {
        libc::mount(
            std::ptr::null(),
            tgt.as_ptr(),
            std::ptr::null(),
            MS_REMOUNT | MS_BIND | MS_RDONLY,
            std::ptr::null(),
        )
    };
    if r2 != 0 {
        eprintln!(
            "fendd: remount-ro {} failed: {}",
            path,
            std::io::Error::last_os_error()
        );
    } else {
        eprintln!("fendd: {} mounted read-only", path);
    }
}

fn setup_networking() {
    run_quiet(&["/bin/ip", "link", "set", "lo", "up"]);
    run_quiet(&["/bin/ip", "link", "set", "eth0", "up"]);

    if std::path::Path::new("/sbin/dhclient").exists() {
        std::process::Command::new("/sbin/dhclient")
            .args(["-1", "-q", "eth0"])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .ok();
    } else if std::path::Path::new("/bin/udhcpc").exists() {
        std::process::Command::new("/bin/udhcpc")
            .args(["-i", "eth0", "-q", "-s", "/bin/simple_dhcp.sh"])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .ok();
    }
}

fn setup_environment() {
    std::fs::create_dir_all("/home/user").ok();
    std::fs::create_dir_all("/etc").ok();

    let needs_user = match std::fs::read_to_string("/etc/passwd") {
        Ok(content) => !content.contains("user:x:1000:"),
        Err(_) => true,
    };
    if needs_user {
        std::fs::write("/etc/passwd", "root:x:0:0:root:/root:/bin/sh\nuser:x:1000:1000::/home/user:/bin/bash\n").ok();
        std::fs::write("/etc/group", "root:x:0:\nuser:x:1000:\n").ok();
    }

    let needs_hosts = match std::fs::read_to_string("/etc/hosts") {
        Ok(content) => !content.contains("localhost"),
        Err(_) => true,
    };
    if needs_hosts {
        std::fs::write("/etc/hosts", "127.0.0.1 localhost fend\n::1 localhost ip6-localhost ip6-loopback\n").ok();
    }

    unsafe { libc::chmod(CString::new("/tmp").unwrap().as_ptr(), 0o1777); }

    if let Some(claude_path) = find_claude_bin() {
        std::fs::create_dir_all("/home/user/.local/bin").ok();
        std::os::unix::fs::symlink(claude_path, "/home/user/.local/bin/claude").ok();
    }

    chown_recursive("/home/user", 1000, 1000);

    let tools_path = build_tools_path();
    std::env::set_var("PATH", &tools_path);
    std::env::set_var("HOME", "/home/user");
    std::env::set_var("TERM", "xterm-256color");
    std::env::set_var("LANG", "C.UTF-8");

    let corepack = find_tool_bin("corepack");
    if let Some(corepack_path) = corepack {
        std::fs::create_dir_all("/usr/local/bin").ok();
        run_quiet(&[&corepack_path, "enable", "--install-directory", "/usr/local/bin"]);
    }
}

fn build_tools_path() -> String {
    let mut paths = Vec::new();

    if let Ok(entries) = std::fs::read_dir("/opt/tools") {
        let mut entries: Vec<_> = entries.flatten().collect();
        entries.sort_by_key(|e| e.file_name());

        for entry in entries {
            let name = entry.file_name();
            let name_str = name.to_string_lossy();

            if name_str.starts_with("node-") {
                let bin = entry.path().join("bin");
                if bin.exists() {
                    paths.push(bin.to_string_lossy().to_string());
                }
            } else if name_str.starts_with("bun-") {
                if entry.path().join("bun").exists() {
                    paths.push(entry.path().to_string_lossy().to_string());
                }
            } else if name_str == "claude" || name_str.starts_with("claude-") {
                if entry.path().join("claude").exists() {
                    paths.push(entry.path().to_string_lossy().to_string());
                }
            }
        }
    }

    paths.extend([
        "/usr/local/sbin".to_string(),
        "/usr/local/bin".to_string(),
        "/usr/sbin".to_string(),
        "/usr/bin".to_string(),
        "/sbin".to_string(),
        "/bin".to_string(),
    ]);
    paths.join(":")
}

fn find_claude_bin() -> Option<String> {
    if let Ok(entries) = std::fs::read_dir("/opt/tools") {
        let mut entries: Vec<_> = entries.flatten().collect();
        entries.sort_by_key(|e| e.file_name());

        for entry in entries {
            let name = entry.file_name();
            let name_str = name.to_string_lossy();
            if name_str == "claude" || name_str.starts_with("claude-") {
                let candidate = entry.path().join("claude");
                if candidate.exists() {
                    return Some(candidate.to_string_lossy().to_string());
                }
            }
        }
    }
    None
}

fn find_tool_bin(name: &str) -> Option<String> {
    if let Ok(entries) = std::fs::read_dir("/opt/tools") {
        for entry in entries.flatten() {
            let candidate = entry.path().join("bin").join(name);
            if candidate.exists() {
                return Some(candidate.to_string_lossy().to_string());
            }
        }
    }
    None
}

fn chown_recursive(path: &str, uid: u32, gid: u32) {
    let c_path = match CString::new(path) {
        Ok(p) => p,
        Err(_) => return,
    };
    unsafe { libc::chown(c_path.as_ptr(), uid, gid); }

    if let Ok(entries) = std::fs::read_dir(path) {
        for entry in entries.flatten() {
            let p = entry.path();
            let ps = p.to_string_lossy().to_string();
            if p.is_dir() {
                chown_recursive(&ps, uid, gid);
            } else if let Ok(cp) = CString::new(ps.as_str()) {
                unsafe { libc::chown(cp.as_ptr(), uid, gid); }
            }
        }
    }
}

fn run_quiet(args: &[&str]) {
    if let Some((cmd, rest)) = args.split_first() {
        std::process::Command::new(cmd)
            .args(rest)
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .ok();
    }
}

/// Fallback: exec shell if vsock fails.
pub fn exec_shell() {
    use std::os::unix::process::CommandExt;
    eprintln!("fendd: falling back to shell");
    let shell = if std::path::Path::new("/bin/bash").exists() {
        "/bin/bash"
    } else {
        "/bin/sh"
    };
    let err = std::process::Command::new(shell).exec();
    eprintln!("fendd: exec shell failed: {}", err);
}
