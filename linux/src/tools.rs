use std::env;
use std::ffi::OsStr;
use std::path::{Path, PathBuf};

const KNOWN_VIRTIOFSD_PATHS: &[&str] = &[
    "/usr/lib/virtiofsd",
    "/usr/libexec/virtiofsd",
    "/usr/lib/qemu/virtiofsd",
];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VirtiofsdMode {
    Direct,
    RootlessUnshare,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolvedVirtiofsd {
    pub path: PathBuf,
    pub mode: VirtiofsdMode,
}

impl ResolvedVirtiofsd {
    pub fn direct(path: impl Into<PathBuf>) -> Self {
        Self {
            path: path.into(),
            mode: VirtiofsdMode::Direct,
        }
    }

    pub fn requires_unshare(&self) -> bool {
        self.mode == VirtiofsdMode::RootlessUnshare
    }

    pub fn display_value(&self) -> String {
        if self.requires_unshare() {
            format!("{} (rootless via unshare)", self.path.display())
        } else {
            self.path.display().to_string()
        }
    }

    pub fn command(&self, socket: &Path, source: &Path) -> (String, Vec<String>) {
        match self.mode {
            VirtiofsdMode::Direct => (
                self.path.display().to_string(),
                vec![
                    format!("--socket-path={}", socket.display()),
                    "--cache=auto".to_string(),
                    "-o".to_string(),
                    format!("source={}", source.display()),
                ],
            ),
            VirtiofsdMode::RootlessUnshare => (
                "unshare".to_string(),
                vec![
                    "-r".to_string(),
                    "--map-auto".to_string(),
                    "--".to_string(),
                    self.path.display().to_string(),
                    format!("--socket-path={}", socket.display()),
                    "--shared-dir".to_string(),
                    source.display().to_string(),
                    "--sandbox".to_string(),
                    "chroot".to_string(),
                ],
            ),
        }
    }
}

pub fn resolve_virtiofsd() -> Option<ResolvedVirtiofsd> {
    resolve_virtiofsd_with_paths(
        env::var_os("FEND_VIRTIOFSD").as_deref(),
        env::var_os("PATH").as_deref(),
        KNOWN_VIRTIOFSD_PATHS,
    )
}

fn resolve_virtiofsd_with_paths(
    override_value: Option<&OsStr>,
    path_value: Option<&OsStr>,
    known_paths: &[&str],
) -> Option<ResolvedVirtiofsd> {
    if let Some(candidate) = override_value.filter(|value| *value != OsStr::new("")) {
        return resolve_candidate(candidate, path_value);
    }

    locate_in_path("virtiofsd", path_value)
        .or_else(|| {
            known_paths
                .iter()
                .map(PathBuf::from)
                .find(|candidate| candidate.is_file())
        })
        .map(new_resolved_virtiofsd)
}

fn resolve_candidate(candidate: &OsStr, path_value: Option<&OsStr>) -> Option<ResolvedVirtiofsd> {
    let candidate_path = PathBuf::from(candidate);
    let resolved = if candidate_path.components().count() > 1 {
        candidate_path.is_file().then_some(candidate_path)
    } else {
        locate_in_path(candidate.to_str()?, path_value)
            .or_else(|| candidate_path.is_file().then_some(candidate_path))
    }?;
    Some(new_resolved_virtiofsd(resolved))
}

fn locate_in_path(program: &str, path_value: Option<&OsStr>) -> Option<PathBuf> {
    let path_value = path_value?;
    env::split_paths(path_value)
        .map(|dir| dir.join(program))
        .find(|candidate| candidate.is_file())
}

fn new_resolved_virtiofsd(path: PathBuf) -> ResolvedVirtiofsd {
    ResolvedVirtiofsd {
        mode: default_virtiofsd_mode(&path),
        path,
    }
}

fn default_virtiofsd_mode(path: &Path) -> VirtiofsdMode {
    if path.ends_with(Path::new("usr/lib/virtiofsd")) {
        VirtiofsdMode::RootlessUnshare
    } else {
        VirtiofsdMode::Direct
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::sync::atomic::{AtomicU64, Ordering};

    static TEST_COUNTER: AtomicU64 = AtomicU64::new(0);

    #[test]
    fn resolver_prefers_override_before_path_lookup() {
        let temp = TestDir::new("override");
        let path_dir = temp.path().join("path");
        let override_dir = temp.path().join("override");
        fs::create_dir_all(&path_dir).unwrap();
        fs::create_dir_all(&override_dir).unwrap();
        fs::write(path_dir.join("virtiofsd"), b"").unwrap();
        fs::write(override_dir.join("virtiofsd"), b"").unwrap();
        let path_value = env::join_paths([path_dir]).unwrap();

        let resolved = resolve_virtiofsd_with_paths(
            Some(override_dir.join("virtiofsd").as_os_str()),
            Some(path_value.as_os_str()),
            &[],
        )
        .unwrap();

        assert_eq!(resolved.path, override_dir.join("virtiofsd"));
    }

    #[test]
    fn resolver_falls_back_to_known_distro_paths() {
        let temp = TestDir::new("known");
        let known_path = temp.path().join("usr/libexec/virtiofsd");
        fs::create_dir_all(known_path.parent().unwrap()).unwrap();
        fs::write(&known_path, b"").unwrap();

        let resolved = resolve_virtiofsd_with_paths(None, None, &[known_path.to_str().unwrap()]);

        assert_eq!(
            resolved,
            Some(ResolvedVirtiofsd {
                path: known_path,
                mode: VirtiofsdMode::Direct,
            })
        );
    }

    #[test]
    fn arch_style_path_selects_rootless_unshare() {
        let temp = TestDir::new("arch");
        let arch_path = temp.path().join("usr/lib/virtiofsd");
        fs::create_dir_all(arch_path.parent().unwrap()).unwrap();
        fs::write(&arch_path, b"").unwrap();

        let resolved =
            resolve_virtiofsd_with_paths(Some(arch_path.as_os_str()), None, &[]).unwrap();

        assert_eq!(resolved.mode, VirtiofsdMode::RootlessUnshare);
        assert!(resolved.display_value().contains("rootless via unshare"));
        assert_eq!(
            resolved.command(Path::new("/tmp/share.sock"), Path::new("/workspace")),
            (
                "unshare".to_string(),
                vec![
                    "-r".to_string(),
                    "--map-auto".to_string(),
                    "--".to_string(),
                    arch_path.display().to_string(),
                    "--socket-path=/tmp/share.sock".to_string(),
                    "--shared-dir".to_string(),
                    "/workspace".to_string(),
                    "--sandbox".to_string(),
                    "chroot".to_string(),
                ]
            )
        );
    }

    struct TestDir {
        path: PathBuf,
    }

    impl TestDir {
        fn new(name: &str) -> Self {
            let id = TEST_COUNTER.fetch_add(1, Ordering::SeqCst);
            let path = PathBuf::from("/tmp").join(format!(
                "fend-linux-tools-{name}-{}-{id}",
                std::process::id()
            ));
            let _ = fs::remove_dir_all(&path);
            fs::create_dir_all(&path).unwrap();
            Self { path }
        }

        fn path(&self) -> &Path {
            &self.path
        }
    }

    impl Drop for TestDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.path);
        }
    }
}
