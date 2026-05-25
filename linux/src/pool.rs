//! Per-host VM pool that keys QEMU instances by canonicalized project path,
//! tracks active CLI sessions, and reaps idle VMs.
//!
//! The pool owns each [`RunningVm`] for the lifetime of the project — dropping
//! the entry triggers `RunningVm::Drop`, which kills QEMU and the virtiofsd
//! sidecars.
//!
//! Concurrency model: a single `Mutex<PoolState>` guards the project→entry
//! map. Boot happens outside the lock so concurrent EnsureVm requests for
//! different projects don't serialize on the slow QEMU spawn. We insert a
//! `Booting` placeholder before unlocking to prevent two threads from
//! racing into a double-boot of the same project.

use std::collections::HashMap;
use std::fmt;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use crate::ipc::{self, VmConfig, VmStatus};
use crate::qemu::{self, LaunchConfig, LaunchPlan, PlanError, RuntimeArtifacts};
use crate::supervisor::{ProcessIo, Supervisor, SupervisorError, SupervisorOptions};
use crate::tools::resolve_virtiofsd;

pub const CID_BASE: u32 = 100;
const CID_MAX: u32 = u32::MAX - 1;
pub const DEFAULT_IDLE_TTL: Duration = Duration::from_secs(30 * 60);
const ENSURE_MAX_RETRIES: u32 = 8;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VmState {
    Booting,
    Running,
    Stopping,
}

impl VmState {
    fn label(self) -> &'static str {
        match self {
            VmState::Booting => "booting",
            VmState::Running => "running",
            VmState::Stopping => "stopping",
        }
    }
}

/// A type-erased running QEMU/virtiofsd stack. Dropping cleans up children.
pub struct VmProcess {
    _inner: Box<dyn Send + 'static>,
}

impl VmProcess {
    pub fn new<T: Send + 'static>(inner: T) -> Self {
        Self {
            _inner: Box::new(inner),
        }
    }
}

impl fmt::Debug for VmProcess {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("VmProcess").finish_non_exhaustive()
    }
}

pub trait VmLauncher: Send + Sync + 'static {
    fn launch(&self, plan: &LaunchPlan, qemu_log: &Path) -> Result<VmProcess, PoolError>;
}

pub struct StdLauncher;

impl VmLauncher for StdLauncher {
    fn launch(&self, plan: &LaunchPlan, qemu_log: &Path) -> Result<VmProcess, PoolError> {
        if let Some(parent) = qemu_log.parent() {
            fs::create_dir_all(parent).map_err(|source| PoolError::Io {
                action: "create qemu log dir",
                path: parent.to_path_buf(),
                source,
            })?;
        }
        let mut supervisor = Supervisor::new(SupervisorOptions {
            qemu_io: ProcessIo::Log(qemu_log.to_path_buf()),
            ..SupervisorOptions::default()
        });
        let running = supervisor
            .launch_plan(plan)
            .map_err(PoolError::Supervisor)?;
        Ok(VmProcess::new(running))
    }
}

#[derive(Debug)]
pub enum PoolError {
    Supervisor(SupervisorError),
    Plan(PlanError),
    Io {
        action: &'static str,
        path: PathBuf,
        source: io::Error,
    },
    Canonicalize {
        path: PathBuf,
        source: io::Error,
    },
    CidExhausted,
    NetworkConflict {
        running: qemu::NetworkMode,
        requested: qemu::NetworkMode,
    },
}

impl fmt::Display for PoolError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Supervisor(error) => write!(f, "{error}"),
            Self::Plan(error) => write!(f, "{error}"),
            Self::Io {
                action,
                path,
                source,
            } => write!(f, "{action} {}: {source}", path.display()),
            Self::Canonicalize { path, source } => {
                write!(f, "canonicalize {}: {source}", path.display())
            }
            Self::CidExhausted => write!(f, "exhausted vsock CID allocation space"),
            Self::NetworkConflict { running, requested } => write!(
                f,
                "VM already running with network={running}; cannot reuse with --vm-network={requested}. \
                 Run `fend stop` first.",
            ),
        }
    }
}

impl std::error::Error for PoolError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Supervisor(error) => Some(error),
            Self::Plan(error) => Some(error),
            Self::Io { source, .. } | Self::Canonicalize { source, .. } => Some(source),
            _ => None,
        }
    }
}

struct VmEntry {
    project: PathBuf,
    cid: u32,
    run_dir: PathBuf,
    state: VmState,
    network: qemu::NetworkMode,
    active_sessions: usize,
    last_used: Instant,
    process: Option<VmProcess>,
}

impl VmEntry {
    fn status(&self) -> VmStatus {
        let idle_secs = if self.active_sessions == 0 {
            self.last_used.elapsed().as_secs()
        } else {
            0
        };
        VmStatus {
            project: self.project.clone(),
            cid: self.cid,
            state: self.state.label().to_string(),
            active_sessions: self.active_sessions,
            idle_secs,
            run_dir: self.run_dir.clone(),
        }
    }
}

struct PoolState {
    vms: HashMap<String, VmEntry>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EnsureOutcome {
    pub cid: u32,
    pub run_dir: PathBuf,
    pub booted: bool,
}

pub struct VmPool {
    inner: Mutex<PoolState>,
    next_cid: AtomicU32,
    state_dir: PathBuf,
    idle_ttl: Duration,
    launcher: Box<dyn VmLauncher>,
}

impl VmPool {
    pub fn new(state_dir: PathBuf) -> Self {
        Self::with_launcher(state_dir, Box::new(StdLauncher))
    }

    pub fn with_launcher(state_dir: PathBuf, launcher: Box<dyn VmLauncher>) -> Self {
        Self {
            inner: Mutex::new(PoolState {
                vms: HashMap::new(),
            }),
            next_cid: AtomicU32::new(CID_BASE),
            state_dir,
            idle_ttl: DEFAULT_IDLE_TTL,
            launcher,
        }
    }

    pub fn set_idle_ttl(&mut self, ttl: Duration) {
        self.idle_ttl = ttl;
    }

    pub fn ensure(&self, config: VmConfig) -> Result<EnsureOutcome, PoolError> {
        let project = canonicalize(&config.project)?;
        let key = ipc::project_key(&project);

        for _ in 0..ENSURE_MAX_RETRIES {
            // Fast path: reuse a running or still-booting VM for this project.
            {
                let mut state = lock(&self.inner);
                if let Some(entry) = state.vms.get_mut(&key) {
                    match entry.state {
                        VmState::Running | VmState::Booting => {
                            if entry.network != config.network {
                                return Err(PoolError::NetworkConflict {
                                    running: entry.network,
                                    requested: config.network,
                                });
                            }
                            entry.active_sessions += 1;
                            entry.last_used = Instant::now();
                            return Ok(EnsureOutcome {
                                cid: entry.cid,
                                run_dir: entry.run_dir.clone(),
                                booted: false,
                            });
                        }
                        VmState::Stopping => {
                            // Wait for the stop to finish, then retry.
                        }
                    }
                } else {
                    // Reserve a slot before unlocking so concurrent ensure() calls
                    // for the same project see it and take the reuse path above.
                    let cid = self.allocate_cid()?;
                    let run_dir = self.state_dir.join("vms").join(format!("{key}-{cid}"));
                    state.vms.insert(
                        key.clone(),
                        VmEntry {
                            project: project.clone(),
                            cid,
                            run_dir: run_dir.clone(),
                            state: VmState::Booting,
                            network: config.network,
                            active_sessions: 1,
                            last_used: Instant::now(),
                            process: None,
                        },
                    );
                    drop(state);

                    // Boot outside the lock so other projects aren't blocked.
                    match self.boot(&project, &config, cid, &run_dir) {
                        Ok(process) => {
                            let mut state = lock(&self.inner);
                            if let Some(entry) = state.vms.get_mut(&key) {
                                entry.state = VmState::Running;
                                entry.process = Some(process);
                            }
                            return Ok(EnsureOutcome {
                                cid,
                                run_dir,
                                booted: true,
                            });
                        }
                        Err(error) => {
                            let removed = {
                                let mut state = lock(&self.inner);
                                state.vms.remove(&key)
                            };
                            drop(removed);
                            return Err(error);
                        }
                    }
                }
            }
            // The Stopping branch fell through; brief pause before retry.
            std::thread::sleep(Duration::from_millis(50));
        }
        Err(PoolError::Io {
            action: "ensure vm",
            path: project,
            source: io::Error::new(
                io::ErrorKind::TimedOut,
                "vm slot remained Stopping across retries",
            ),
        })
    }

    /// Decrement the active-session counter for a project. Idempotent if the
    /// project is no longer in the pool (e.g. VM was forcibly stopped).
    pub fn release(&self, project: &Path) {
        let canonical = fs::canonicalize(project).unwrap_or_else(|_| project.to_path_buf());
        let key = ipc::project_key(&canonical);
        let mut state = lock(&self.inner);
        if let Some(entry) = state.vms.get_mut(&key) {
            entry.active_sessions = entry.active_sessions.saturating_sub(1);
            if entry.active_sessions == 0 {
                entry.last_used = Instant::now();
            }
        }
    }

    /// Stop a specific project's VM (or all VMs when `project` is `None`).
    /// Returns the number of VMs removed.
    pub fn stop(&self, project: Option<&Path>) -> usize {
        let mut removed = Vec::new();
        {
            let mut state = lock(&self.inner);
            match project {
                Some(path) => {
                    let canonical = fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
                    let key = ipc::project_key(&canonical);
                    if let Some(mut entry) = state.vms.remove(&key) {
                        entry.state = VmState::Stopping;
                        removed.push(entry);
                    }
                }
                None => {
                    for (_, mut entry) in state.vms.drain() {
                        entry.state = VmState::Stopping;
                        removed.push(entry);
                    }
                }
            }
        }
        let count = removed.len();
        // Drop the entries (which drops each VmProcess → kills QEMU/virtiofsd)
        // outside the lock so concurrent ensure() calls aren't blocked by it.
        drop(removed);
        count
    }

    /// Stop VMs that have had zero active sessions for longer than the idle
    /// TTL. Returns the number stopped.
    pub fn reap(&self) -> usize {
        let now = Instant::now();
        let mut removed = Vec::new();
        {
            let mut state = lock(&self.inner);
            let stale_keys: Vec<String> = state
                .vms
                .iter()
                .filter(|(_, entry)| {
                    entry.active_sessions == 0
                        && entry.state == VmState::Running
                        && now.duration_since(entry.last_used) > self.idle_ttl
                })
                .map(|(key, _)| key.clone())
                .collect();
            for key in stale_keys {
                if let Some(mut entry) = state.vms.remove(&key) {
                    entry.state = VmState::Stopping;
                    removed.push(entry);
                }
            }
        }
        let count = removed.len();
        drop(removed);
        count
    }

    pub fn status(&self) -> Vec<VmStatus> {
        let state = lock(&self.inner);
        let mut vms: Vec<VmStatus> = state.vms.values().map(VmEntry::status).collect();
        vms.sort_by(|a, b| a.project.cmp(&b.project));
        vms
    }

    fn allocate_cid(&self) -> Result<u32, PoolError> {
        let cid = self.next_cid.fetch_add(1, Ordering::SeqCst);
        if cid >= CID_MAX {
            return Err(PoolError::CidExhausted);
        }
        Ok(cid)
    }

    fn boot(
        &self,
        project: &Path,
        config: &VmConfig,
        cid: u32,
        run_dir: &Path,
    ) -> Result<VmProcess, PoolError> {
        fs::create_dir_all(run_dir).map_err(|source| PoolError::Io {
            action: "create vm run dir",
            path: run_dir.to_path_buf(),
            source,
        })?;
        let mut launch_config = LaunchConfig::new(
            RuntimeArtifacts::from_runtime_dir(&config.runtime_dir),
            project,
            &config.cache_dir,
            &config.tools_dir,
            run_dir,
            config.epoch,
        );
        if let Some(virtiofsd) = resolve_virtiofsd() {
            launch_config.virtiofsd = virtiofsd;
        }
        launch_config.guest_cid = cid;
        launch_config.cpus = config.cpus;
        launch_config.memory_mib = config.memory_mib;
        launch_config.network = config.network;
        launch_config.guest_workspace = config.guest_workspace.clone();

        let plan = qemu::build_launch_plan(&launch_config).map_err(PoolError::Plan)?;
        let qemu_log = run_dir.join("logs/qemu.log");
        self.launcher.launch(&plan, &qemu_log)
    }
}

fn canonicalize(path: &Path) -> Result<PathBuf, PoolError> {
    fs::canonicalize(path).map_err(|source| PoolError::Canonicalize {
        path: path.to_path_buf(),
        source,
    })
}

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicUsize;
    use std::sync::Arc;

    fn temp_state_dir(name: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!(
            "fend-pool-{name}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos(),
        ));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(&path).unwrap();
        path
    }

    fn make_config(project: &Path) -> VmConfig {
        VmConfig {
            project: project.to_path_buf(),
            runtime_dir: PathBuf::from("/nonexistent/runtime"),
            cache_dir: PathBuf::from("/nonexistent/cache"),
            tools_dir: PathBuf::from("/nonexistent/tools"),
            guest_workspace: "/workspace".into(),
            cpus: 2,
            memory_mib: 2048,
            network: qemu::NetworkMode::Off,
            epoch: 1,
        }
    }

    struct FakeLauncher {
        calls: Arc<AtomicUsize>,
    }

    impl VmLauncher for FakeLauncher {
        fn launch(&self, _plan: &LaunchPlan, _qemu_log: &Path) -> Result<VmProcess, PoolError> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            Ok(VmProcess::new(()))
        }
    }

    struct CountingDrop {
        counter: Arc<AtomicUsize>,
    }

    impl Drop for CountingDrop {
        fn drop(&mut self) {
            self.counter.fetch_add(1, Ordering::SeqCst);
        }
    }

    struct DropTrackingLauncher {
        drops: Arc<AtomicUsize>,
    }

    impl VmLauncher for DropTrackingLauncher {
        fn launch(&self, _plan: &LaunchPlan, _qemu_log: &Path) -> Result<VmProcess, PoolError> {
            Ok(VmProcess::new(CountingDrop {
                counter: self.drops.clone(),
            }))
        }
    }

    struct FailingLauncher;
    impl VmLauncher for FailingLauncher {
        fn launch(&self, _plan: &LaunchPlan, _qemu_log: &Path) -> Result<VmProcess, PoolError> {
            Err(PoolError::CidExhausted)
        }
    }

    #[test]
    fn ensure_boots_a_new_vm_then_reuses_it() {
        let state_dir = temp_state_dir("reuse");
        let workspace = state_dir.join("ws");
        fs::create_dir_all(&workspace).unwrap();
        let calls = Arc::new(AtomicUsize::new(0));
        let pool = VmPool::with_launcher(
            state_dir.clone(),
            Box::new(FakeLauncher {
                calls: calls.clone(),
            }),
        );

        let first = pool.ensure(make_config(&workspace)).unwrap();
        assert!(first.booted);
        assert_eq!(calls.load(Ordering::SeqCst), 1);

        let second = pool.ensure(make_config(&workspace)).unwrap();
        assert!(!second.booted);
        assert_eq!(second.cid, first.cid);
        assert_eq!(calls.load(Ordering::SeqCst), 1);

        let status = pool.status();
        assert_eq!(status.len(), 1);
        assert_eq!(status[0].active_sessions, 2);
    }

    #[test]
    fn release_decrements_session_count() {
        let state_dir = temp_state_dir("release");
        let workspace = state_dir.join("ws");
        fs::create_dir_all(&workspace).unwrap();
        let pool = VmPool::with_launcher(
            state_dir,
            Box::new(FakeLauncher {
                calls: Arc::new(AtomicUsize::new(0)),
            }),
        );
        pool.ensure(make_config(&workspace)).unwrap();
        pool.ensure(make_config(&workspace)).unwrap();
        assert_eq!(pool.status()[0].active_sessions, 2);
        pool.release(&workspace);
        assert_eq!(pool.status()[0].active_sessions, 1);
        pool.release(&workspace);
        assert_eq!(pool.status()[0].active_sessions, 0);
    }

    #[test]
    fn stop_removes_vm_and_drops_handle() {
        let state_dir = temp_state_dir("stop");
        let workspace = state_dir.join("ws");
        fs::create_dir_all(&workspace).unwrap();
        let drops = Arc::new(AtomicUsize::new(0));
        let pool = VmPool::with_launcher(
            state_dir,
            Box::new(DropTrackingLauncher {
                drops: drops.clone(),
            }),
        );
        pool.ensure(make_config(&workspace)).unwrap();
        let stopped = pool.stop(Some(&workspace));
        assert_eq!(stopped, 1);
        assert_eq!(drops.load(Ordering::SeqCst), 1);
        assert!(pool.status().is_empty());
    }

    #[test]
    fn stop_all_removes_every_vm() {
        let state_dir = temp_state_dir("stop-all");
        let a = state_dir.join("a");
        let b = state_dir.join("b");
        fs::create_dir_all(&a).unwrap();
        fs::create_dir_all(&b).unwrap();
        let pool = VmPool::with_launcher(
            state_dir,
            Box::new(FakeLauncher {
                calls: Arc::new(AtomicUsize::new(0)),
            }),
        );
        pool.ensure(make_config(&a)).unwrap();
        pool.ensure(make_config(&b)).unwrap();
        assert_eq!(pool.stop(None), 2);
        assert!(pool.status().is_empty());
    }

    #[test]
    fn reap_stops_idle_vm_and_keeps_active_one() {
        let state_dir = temp_state_dir("reap");
        let a = state_dir.join("a");
        let b = state_dir.join("b");
        fs::create_dir_all(&a).unwrap();
        fs::create_dir_all(&b).unwrap();
        let mut pool = VmPool::with_launcher(
            state_dir,
            Box::new(FakeLauncher {
                calls: Arc::new(AtomicUsize::new(0)),
            }),
        );
        pool.set_idle_ttl(Duration::from_millis(1));
        pool.ensure(make_config(&a)).unwrap();
        pool.ensure(make_config(&b)).unwrap();
        pool.release(&a); // a now has 0 active sessions
                          // b stays at 1 active session.
        std::thread::sleep(Duration::from_millis(20));
        let reaped = pool.reap();
        assert_eq!(reaped, 1);
        let status = pool.status();
        assert_eq!(status.len(), 1);
        assert_eq!(status[0].project, fs::canonicalize(&b).unwrap());
    }

    #[test]
    fn boot_failure_does_not_leak_slot() {
        let state_dir = temp_state_dir("fail");
        let workspace = state_dir.join("ws");
        fs::create_dir_all(&workspace).unwrap();
        let pool = VmPool::with_launcher(state_dir, Box::new(FailingLauncher));
        let error = pool.ensure(make_config(&workspace)).unwrap_err();
        assert!(matches!(error, PoolError::CidExhausted));
        assert!(pool.status().is_empty());
    }

    #[test]
    fn cid_increments_per_vm() {
        let state_dir = temp_state_dir("cid");
        let a = state_dir.join("a");
        let b = state_dir.join("b");
        fs::create_dir_all(&a).unwrap();
        fs::create_dir_all(&b).unwrap();
        let pool = VmPool::with_launcher(
            state_dir,
            Box::new(FakeLauncher {
                calls: Arc::new(AtomicUsize::new(0)),
            }),
        );
        let ra = pool.ensure(make_config(&a)).unwrap();
        let rb = pool.ensure(make_config(&b)).unwrap();
        assert_ne!(ra.cid, rb.cid);
        assert!(ra.cid >= CID_BASE);
        assert!(rb.cid >= CID_BASE);
    }

    #[test]
    fn ensure_rejects_conflicting_network_mode() {
        let state_dir = temp_state_dir("netconflict");
        let workspace = state_dir.join("ws");
        fs::create_dir_all(&workspace).unwrap();
        let pool = VmPool::with_launcher(
            state_dir,
            Box::new(FakeLauncher {
                calls: Arc::new(AtomicUsize::new(0)),
            }),
        );
        pool.ensure(make_config(&workspace)).unwrap();
        let mut conflicting = make_config(&workspace);
        conflicting.network = qemu::NetworkMode::User;
        let error = pool.ensure(conflicting).unwrap_err();
        assert!(matches!(error, PoolError::NetworkConflict { .. }));
    }

    #[test]
    fn ensure_propagates_canonicalize_failure() {
        let pool = VmPool::with_launcher(
            temp_state_dir("noworkspace"),
            Box::new(FakeLauncher {
                calls: Arc::new(AtomicUsize::new(0)),
            }),
        );
        let mut config = make_config(Path::new("/nonexistent/workspace"));
        config.project = PathBuf::from("/nonexistent/workspace/path/that/does/not/exist");
        let error = pool.ensure(config).unwrap_err();
        assert!(matches!(error, PoolError::Canonicalize { .. }));
    }
}
