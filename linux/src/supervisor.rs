use std::fmt;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use crate::qemu::{LaunchPlan, SharePlan};

const STOP_POLL_INTERVAL: Duration = Duration::from_millis(50);
const STOP_KILL_TIMEOUT: Duration = Duration::from_secs(1);

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProcessIo {
    Inherit,
    Log(PathBuf),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProcessSpec {
    pub label: String,
    pub program: String,
    pub args: Vec<String>,
    pub io: ProcessIo,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProcessExit {
    pub code: Option<i32>,
}

impl fmt::Display for ProcessExit {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self.code {
            Some(code) => write!(f, "exit code {code}"),
            None => write!(f, "terminated by signal"),
        }
    }
}

impl From<std::process::ExitStatus> for ProcessExit {
    fn from(status: std::process::ExitStatus) -> Self {
        Self {
            code: status.code(),
        }
    }
}

pub trait ManagedChild {
    fn id(&self) -> u32;
    fn try_wait(&mut self) -> io::Result<Option<ProcessExit>>;
    fn kill(&mut self) -> io::Result<()>;
    fn wait(&mut self) -> io::Result<ProcessExit>;
}

pub trait ProcessSpawner {
    type Child: ManagedChild;

    fn spawn(&mut self, spec: &ProcessSpec) -> io::Result<Self::Child>;
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SupervisorOptions {
    pub socket_timeout: Duration,
    pub poll_interval: Duration,
    pub qemu_io: ProcessIo,
}

impl Default for SupervisorOptions {
    fn default() -> Self {
        Self {
            socket_timeout: Duration::from_secs(10),
            poll_interval: Duration::from_millis(100),
            qemu_io: ProcessIo::Inherit,
        }
    }
}

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct StopReport {
    pub terminated: Vec<String>,
    pub stale: Vec<String>,
}

#[derive(Debug)]
pub enum SupervisorError {
    Io {
        action: &'static str,
        path: Option<PathBuf>,
        source: io::Error,
    },
    SocketAlreadyExists(PathBuf),
    SocketTimeout {
        label: String,
        path: PathBuf,
        log_path: PathBuf,
        timeout: Duration,
    },
    ShareSourceMissing {
        label: String,
        path: PathBuf,
    },
    ShareSourceNotDirectory {
        label: String,
        path: PathBuf,
    },
    ProcessExited {
        label: String,
        status: ProcessExit,
        log_path: PathBuf,
    },
}

impl SupervisorError {
    fn io(action: &'static str, path: Option<PathBuf>, source: io::Error) -> Self {
        Self::Io {
            action,
            path,
            source,
        }
    }
}

impl fmt::Display for SupervisorError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io {
                action,
                path,
                source,
            } => {
                if let Some(path) = path {
                    write!(f, "{action} {}: {source}", path.display())
                } else {
                    write!(f, "{action}: {source}")
                }
            }
            Self::SocketAlreadyExists(path) => {
                write!(f, "virtiofsd socket already exists: {}", path.display())
            }
            Self::SocketTimeout {
                label,
                path,
                log_path,
                timeout,
            } => write!(
                f,
                "timed out after {:.1}s waiting for {label} socket {} (see {})",
                timeout.as_secs_f64(),
                path.display(),
                log_path.display()
            ),
            Self::ShareSourceMissing { label, path } => {
                write!(f, "{label} share source is missing: {}", path.display())
            }
            Self::ShareSourceNotDirectory { label, path } => {
                write!(
                    f,
                    "{label} share source is not a directory: {}",
                    path.display()
                )
            }
            Self::ProcessExited {
                label,
                status,
                log_path,
            } => {
                write!(
                    f,
                    "{label} exited before becoming ready ({status}); see {}",
                    log_path.display()
                )
            }
        }
    }
}

impl std::error::Error for SupervisorError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Io { source, .. } => Some(source),
            _ => None,
        }
    }
}

pub struct StdProcessSpawner;

impl ProcessSpawner for StdProcessSpawner {
    type Child = std::process::Child;

    fn spawn(&mut self, spec: &ProcessSpec) -> io::Result<Self::Child> {
        let mut command = Command::new(&spec.program);
        command.args(&spec.args);

        match &spec.io {
            ProcessIo::Inherit => {
                command
                    .stdin(Stdio::inherit())
                    .stdout(Stdio::inherit())
                    .stderr(Stdio::inherit());
            }
            ProcessIo::Log(path) => {
                let output = fs::File::create(path)?;
                let error = output.try_clone()?;
                command
                    .stdin(Stdio::null())
                    .stdout(Stdio::from(output))
                    .stderr(Stdio::from(error));
            }
        }

        command.spawn()
    }
}

impl ManagedChild for std::process::Child {
    fn id(&self) -> u32 {
        std::process::Child::id(self)
    }

    fn try_wait(&mut self) -> io::Result<Option<ProcessExit>> {
        std::process::Child::try_wait(self).map(|status| status.map(ProcessExit::from))
    }

    fn kill(&mut self) -> io::Result<()> {
        std::process::Child::kill(self)
    }

    fn wait(&mut self) -> io::Result<ProcessExit> {
        std::process::Child::wait(self).map(ProcessExit::from)
    }
}

pub struct Supervisor<S: ProcessSpawner = StdProcessSpawner> {
    spawner: S,
    options: SupervisorOptions,
}

impl Supervisor<StdProcessSpawner> {
    pub fn new(options: SupervisorOptions) -> Self {
        Self {
            spawner: StdProcessSpawner,
            options,
        }
    }
}

impl<S: ProcessSpawner> Supervisor<S> {
    pub fn with_spawner(spawner: S, options: SupervisorOptions) -> Self {
        Self { spawner, options }
    }

    pub fn launch_plan(
        &mut self,
        plan: &LaunchPlan,
    ) -> Result<RunningVm<S::Child>, SupervisorError> {
        prepare_plan_paths(plan)?;

        let mut virtiofsd = Vec::new();
        let mut sockets = Vec::new();
        let mut pid_files = Vec::new();

        for share in &plan.shares {
            if share.socket.exists() {
                cleanup_pid_files(&pid_files);
                cleanup_children(&mut virtiofsd);
                return Err(SupervisorError::SocketAlreadyExists(share.socket.clone()));
            }

            let (program, args) = share.virtiofsd_command();
            let spec = ProcessSpec {
                label: format!("virtiofsd-{}", share.name),
                program,
                args,
                io: ProcessIo::Log(share.log.clone()),
            };
            let mut child = self
                .spawner
                .spawn(&spec)
                .map_err(|source| SupervisorError::io("spawn virtiofsd", None, source))?;

            if let Err(error) = wait_for_socket(
                &mut child,
                &spec.label,
                &share.socket,
                &share.log,
                &self.options,
            ) {
                cleanup_child(&mut child);
                cleanup_pid_files(&pid_files);
                cleanup_children(&mut virtiofsd);
                cleanup_sockets(&sockets);
                return Err(error);
            }

            let pid_file = pid_file_path(&plan.run_dir, &spec.label);
            if let Err(source) = write_pid_file(&pid_file, child.id()) {
                cleanup_child(&mut child);
                cleanup_pid_files(&pid_files);
                cleanup_children(&mut virtiofsd);
                cleanup_sockets(&sockets);
                return Err(SupervisorError::io(
                    "write pid file",
                    Some(pid_file),
                    source,
                ));
            }

            pid_files.push(pid_file);
            sockets.push(share.socket.clone());
            virtiofsd.push(child);
        }

        let qemu_spec = ProcessSpec {
            label: "qemu".to_string(),
            program: plan.qemu_program.to_string(),
            args: plan.qemu_args.clone(),
            io: self.options.qemu_io.clone(),
        };
        let qemu = match self.spawner.spawn(&qemu_spec) {
            Ok(child) => child,
            Err(source) => {
                cleanup_pid_files(&pid_files);
                cleanup_children(&mut virtiofsd);
                cleanup_sockets(&sockets);
                return Err(SupervisorError::io("spawn qemu", None, source));
            }
        };

        let qemu_pid_file = pid_file_path(&plan.run_dir, &qemu_spec.label);
        if let Err(source) = write_pid_file(&qemu_pid_file, qemu.id()) {
            let mut qemu = qemu;
            cleanup_child(&mut qemu);
            cleanup_pid_files(&pid_files);
            cleanup_children(&mut virtiofsd);
            cleanup_sockets(&sockets);
            return Err(SupervisorError::io(
                "write pid file",
                Some(qemu_pid_file),
                source,
            ));
        }
        pid_files.push(qemu_pid_file);

        Ok(RunningVm {
            qemu: Some(qemu),
            virtiofsd,
            sockets,
            pid_files,
            cleaned_up: false,
        })
    }
}

#[derive(Debug)]
pub struct RunningVm<C: ManagedChild> {
    qemu: Option<C>,
    virtiofsd: Vec<C>,
    sockets: Vec<PathBuf>,
    pid_files: Vec<PathBuf>,
    cleaned_up: bool,
}

impl<C: ManagedChild> RunningVm<C> {
    pub fn qemu_id(&self) -> Option<u32> {
        self.qemu.as_ref().map(ManagedChild::id)
    }

    pub fn virtiofsd_count(&self) -> usize {
        self.virtiofsd.len()
    }

    pub fn wait_for_qemu(&mut self) -> io::Result<ProcessExit> {
        let Some(mut qemu) = self.qemu.take() else {
            return Ok(ProcessExit { code: Some(0) });
        };
        qemu.wait()
    }

    pub fn stop(mut self) {
        self.cleanup();
    }

    fn cleanup(&mut self) {
        if self.cleaned_up {
            return;
        }
        if let Some(mut qemu) = self.qemu.take() {
            cleanup_child(&mut qemu);
        }
        cleanup_children(&mut self.virtiofsd);
        cleanup_pid_files(&self.pid_files);
        cleanup_sockets(&self.sockets);
        self.cleaned_up = true;
    }
}

impl<C: ManagedChild> Drop for RunningVm<C> {
    fn drop(&mut self) {
        self.cleanup();
    }
}

fn prepare_plan_paths(plan: &LaunchPlan) -> Result<(), SupervisorError> {
    fs::create_dir_all(&plan.run_dir).map_err(|source| {
        SupervisorError::io("create run directory", Some(plan.run_dir.clone()), source)
    })?;
    fs::create_dir_all(&plan.log_dir).map_err(|source| {
        SupervisorError::io("create log directory", Some(plan.log_dir.clone()), source)
    })?;

    for share in &plan.shares {
        prepare_share_source(share)?;
        if let Some(parent) = share.socket.parent() {
            fs::create_dir_all(parent).map_err(|source| {
                SupervisorError::io(
                    "create socket directory",
                    Some(parent.to_path_buf()),
                    source,
                )
            })?;
        }
        if let Some(parent) = share.log.parent() {
            fs::create_dir_all(parent).map_err(|source| {
                SupervisorError::io("create log directory", Some(parent.to_path_buf()), source)
            })?;
        }
    }

    Ok(())
}

fn prepare_share_source(share: &SharePlan) -> Result<(), SupervisorError> {
    if share.name == "workspace" {
        return require_existing_directory(share.name, &share.source);
    }

    fs::create_dir_all(&share.source).map_err(|source| {
        SupervisorError::io("create share source", Some(share.source.clone()), source)
    })
}

fn require_existing_directory(label: &str, path: &Path) -> Result<(), SupervisorError> {
    let metadata = match fs::metadata(path) {
        Ok(metadata) => metadata,
        Err(source) if source.kind() == io::ErrorKind::NotFound => {
            return Err(SupervisorError::ShareSourceMissing {
                label: label.to_string(),
                path: path.to_path_buf(),
            });
        }
        Err(source) => {
            return Err(SupervisorError::io(
                "inspect share source",
                Some(path.to_path_buf()),
                source,
            ));
        }
    };

    if metadata.is_dir() {
        Ok(())
    } else {
        Err(SupervisorError::ShareSourceNotDirectory {
            label: label.to_string(),
            path: path.to_path_buf(),
        })
    }
}

fn wait_for_socket<C: ManagedChild>(
    child: &mut C,
    label: &str,
    socket: &Path,
    log_path: &Path,
    options: &SupervisorOptions,
) -> Result<(), SupervisorError> {
    let start = Instant::now();
    loop {
        if path_is_socket(socket) {
            return Ok(());
        }
        if let Some(status) = child
            .try_wait()
            .map_err(|source| SupervisorError::io("check child status", None, source))?
        {
            return Err(SupervisorError::ProcessExited {
                label: label.to_string(),
                status,
                log_path: log_path.to_path_buf(),
            });
        }
        if start.elapsed() >= options.socket_timeout {
            return Err(SupervisorError::SocketTimeout {
                label: label.to_string(),
                path: socket.to_path_buf(),
                log_path: log_path.to_path_buf(),
                timeout: options.socket_timeout,
            });
        }
        thread::sleep(options.poll_interval);
    }
}

fn path_is_socket(path: &Path) -> bool {
    #[cfg(test)]
    {
        if fs::metadata(path)
            .map(|metadata| metadata.is_file())
            .unwrap_or(false)
        {
            return true;
        }
    }

    #[cfg(unix)]
    {
        use std::os::unix::fs::FileTypeExt;

        fs::metadata(path)
            .map(|metadata| metadata.file_type().is_socket())
            .unwrap_or(false)
    }

    #[cfg(not(unix))]
    {
        let _ = path;
        false
    }
}

fn cleanup_children<C: ManagedChild>(children: &mut Vec<C>) {
    for child in children {
        cleanup_child(child);
    }
}

fn cleanup_child<C: ManagedChild>(child: &mut C) {
    match child.try_wait() {
        Ok(Some(_)) => {}
        Ok(None) => {
            let _ = child.kill();
        }
        Err(_) => {
            let _ = child.kill();
        }
    }
    let _ = child.wait();
}

fn cleanup_sockets(sockets: &[PathBuf]) {
    for socket in sockets {
        if path_is_socket(socket) {
            let _ = fs::remove_file(socket);
        }
    }
}

fn cleanup_pid_files(paths: &[PathBuf]) {
    for path in paths {
        let _ = fs::remove_file(path);
    }
}

fn pid_file_path(run_dir: &Path, label: &str) -> PathBuf {
    run_dir.join(format!("{label}.pid"))
}

fn write_pid_file(path: &Path, pid: u32) -> io::Result<()> {
    fs::write(path, format!("{pid}\n"))
}

pub fn stop_run_dir(run_dir: &Path, timeout: Duration) -> Result<StopReport, SupervisorError> {
    let pid_files = pid_files_in_run_dir(run_dir)?;
    let mut report = StopReport::default();

    for pid_file in pid_files {
        let label = pid_file
            .file_stem()
            .map(|value| value.to_string_lossy().to_string())
            .unwrap_or_else(|| pid_file.display().to_string());
        let Some(pid) = read_pid_file(&pid_file)? else {
            let _ = fs::remove_file(&pid_file);
            report.stale.push(label);
            continue;
        };

        if terminate_pid(pid, timeout)
            .map_err(|source| SupervisorError::io("stop process", Some(pid_file.clone()), source))?
        {
            report.terminated.push(label);
        } else {
            report.stale.push(label);
        }

        let _ = fs::remove_file(&pid_file);
    }

    cleanup_run_dir_sockets(run_dir)?;
    Ok(report)
}

fn pid_files_in_run_dir(run_dir: &Path) -> Result<Vec<PathBuf>, SupervisorError> {
    let entries = fs::read_dir(run_dir).map_err(|source| {
        SupervisorError::io("read run directory", Some(run_dir.to_path_buf()), source)
    })?;
    let mut paths = entries
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| path.extension().and_then(|value| value.to_str()) == Some("pid"))
        .collect::<Vec<_>>();
    paths.sort_by_key(|path| {
        let name = path
            .file_name()
            .and_then(|value| value.to_str())
            .unwrap_or("");
        (name != "qemu.pid", name.to_string())
    });
    Ok(paths)
}

fn read_pid_file(path: &Path) -> Result<Option<u32>, SupervisorError> {
    let contents = fs::read_to_string(path)
        .map_err(|source| SupervisorError::io("read pid file", Some(path.to_path_buf()), source))?;
    let pid = contents.trim();
    if pid.is_empty() {
        return Ok(None);
    }
    match pid.parse::<u32>() {
        Ok(pid) => Ok(Some(pid)),
        Err(_) => Ok(None),
    }
}

fn terminate_pid(pid: u32, timeout: Duration) -> io::Result<bool> {
    if !send_signal(pid, libc::SIGTERM)? {
        return Ok(false);
    }

    if wait_for_pid_exit(pid, timeout)? {
        return Ok(true);
    }

    if send_signal(pid, libc::SIGKILL)? {
        let _ = wait_for_pid_exit(pid, STOP_KILL_TIMEOUT)?;
    }

    Ok(true)
}

fn wait_for_pid_exit(pid: u32, timeout: Duration) -> io::Result<bool> {
    let start = Instant::now();
    loop {
        if !process_exists(pid)? {
            return Ok(true);
        }
        if start.elapsed() >= timeout {
            return Ok(false);
        }
        thread::sleep(STOP_POLL_INTERVAL);
    }
}

fn send_signal(pid: u32, signal: libc::c_int) -> io::Result<bool> {
    let ret = unsafe { libc::kill(pid as i32, signal) };
    if ret == 0 {
        return Ok(true);
    }

    let error = io::Error::last_os_error();
    match error.raw_os_error() {
        Some(libc::ESRCH) => Ok(false),
        _ => Err(error),
    }
}

fn process_exists(pid: u32) -> io::Result<bool> {
    let ret = unsafe { libc::kill(pid as i32, 0) };
    if ret == 0 {
        return Ok(true);
    }

    let error = io::Error::last_os_error();
    match error.raw_os_error() {
        Some(libc::ESRCH) => Ok(false),
        Some(libc::EPERM) => Ok(true),
        _ => Err(error),
    }
}

fn cleanup_run_dir_sockets(run_dir: &Path) -> Result<(), SupervisorError> {
    let entries = fs::read_dir(run_dir).map_err(|source| {
        SupervisorError::io("read run directory", Some(run_dir.to_path_buf()), source)
    })?;
    for path in entries.flatten().map(|entry| entry.path()) {
        if path.extension().and_then(|value| value.to_str()) == Some("sock") {
            let _ = fs::remove_file(path);
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::collections::HashSet;
    use std::process::Command;
    use std::rc::Rc;
    use std::sync::atomic::{AtomicU64, Ordering};

    use super::*;
    use crate::qemu::{build_launch_plan, LaunchConfig, NetworkMode, RuntimeArtifacts};

    static TEST_COUNTER: AtomicU64 = AtomicU64::new(0);

    #[test]
    fn launch_plan_spawns_virtiofsd_then_qemu_and_drop_cleans_up() {
        let temp = TestDir::new("happy");
        let plan = sample_plan(temp.path());
        let spawner = FakeSpawner::new().with_socket_creation(true);
        let state = spawner.state.clone();
        let mut supervisor = Supervisor::with_spawner(spawner, fast_options());

        {
            let vm = supervisor.launch_plan(&plan).unwrap();

            assert_eq!(vm.qemu_id(), Some(4));
            assert_eq!(vm.virtiofsd_count(), 3);
            assert!(path_is_socket(&plan.shares[0].socket));
            assert!(plan.run_dir.join("virtiofsd-workspace.pid").exists());
            assert!(plan.run_dir.join("virtiofsd-cache.pid").exists());
            assert!(plan.run_dir.join("virtiofsd-tools.pid").exists());
            assert!(plan.run_dir.join("qemu.pid").exists());
            assert!(plan.shares[1].source.is_dir());
            assert!(plan.shares[2].source.is_dir());
            assert!(plan.log_dir.is_dir());
        }

        let state = state.borrow();
        assert_eq!(
            state
                .calls
                .iter()
                .map(|call| call.label.as_str())
                .collect::<Vec<_>>(),
            [
                "virtiofsd-workspace",
                "virtiofsd-cache",
                "virtiofsd-tools",
                "qemu"
            ]
        );
        assert!(matches!(state.calls[0].io, ProcessIo::Log(_)));
        assert!(matches!(state.calls[3].io, ProcessIo::Inherit));
        assert!(state.children.iter().all(|child| child.borrow().killed));
        assert!(state.children.iter().all(|child| child.borrow().waited));
        assert!(!plan.shares[0].socket.exists());
    }

    #[test]
    fn launch_plan_rejects_missing_workspace_before_spawning() {
        let temp = TestDir::new("missing-workspace");
        let plan = sample_plan(temp.path());
        fs::remove_dir_all(&plan.shares[0].source).unwrap();
        let spawner = FakeSpawner::new().with_socket_creation(true);
        let state = spawner.state.clone();
        let mut supervisor = Supervisor::with_spawner(spawner, fast_options());

        let error = supervisor.launch_plan(&plan).unwrap_err();

        assert!(matches!(
            error,
            SupervisorError::ShareSourceMissing {
                ref label,
                ref path
            } if label == "workspace" && path == &plan.shares[0].source
        ));
        assert!(state.borrow().calls.is_empty());
    }

    #[test]
    fn launch_plan_rejects_workspace_file_before_spawning() {
        let temp = TestDir::new("workspace-file");
        let plan = sample_plan(temp.path());
        fs::remove_dir_all(&plan.shares[0].source).unwrap();
        fs::write(&plan.shares[0].source, b"not a directory").unwrap();
        let spawner = FakeSpawner::new().with_socket_creation(true);
        let state = spawner.state.clone();
        let mut supervisor = Supervisor::with_spawner(spawner, fast_options());

        let error = supervisor.launch_plan(&plan).unwrap_err();

        assert!(matches!(
            error,
            SupervisorError::ShareSourceNotDirectory {
                ref label,
                ref path
            } if label == "workspace" && path == &plan.shares[0].source
        ));
        assert!(state.borrow().calls.is_empty());
    }

    #[test]
    fn launch_plan_cleans_up_started_children_when_socket_times_out() {
        let temp = TestDir::new("timeout");
        let plan = sample_plan(temp.path());
        let spawner = FakeSpawner::new();
        let state = spawner.state.clone();
        let mut supervisor = Supervisor::with_spawner(spawner, fast_options());

        let error = supervisor.launch_plan(&plan).unwrap_err();

        assert!(matches!(error, SupervisorError::SocketTimeout { .. }));
        let state = state.borrow();
        assert_eq!(state.calls.len(), 1);
        assert_eq!(state.calls[0].label, "virtiofsd-workspace");
        assert!(state.children[0].borrow().killed);
        assert!(state.children[0].borrow().waited);
    }

    #[test]
    fn launch_plan_cleans_up_virtiofsd_when_qemu_spawn_fails() {
        let temp = TestDir::new("qemu-fail");
        let plan = sample_plan(temp.path());
        let spawner = FakeSpawner::new()
            .with_socket_creation(true)
            .with_failed_program("qemu-system-x86_64");
        let state = spawner.state.clone();
        let mut supervisor = Supervisor::with_spawner(spawner, fast_options());

        let error = supervisor.launch_plan(&plan).unwrap_err();

        assert!(matches!(
            error,
            SupervisorError::Io {
                action: "spawn qemu",
                ..
            }
        ));
        let state = state.borrow();
        assert_eq!(state.calls.len(), 4);
        assert!(state.children.iter().all(|child| child.borrow().killed));
        assert!(state.children.iter().all(|child| child.borrow().waited));
        assert!(!plan.shares[0].socket.exists());
    }

    #[test]
    fn launch_plan_reports_child_exit_before_socket_ready() {
        let temp = TestDir::new("child-exit");
        let plan = sample_plan(temp.path());
        let spawner = FakeSpawner::new().with_exited_label("virtiofsd-workspace");
        let mut supervisor = Supervisor::with_spawner(spawner, fast_options());

        let error = supervisor.launch_plan(&plan).unwrap_err();

        assert!(matches!(
            error,
            SupervisorError::ProcessExited {
                ref label,
                status: ProcessExit { code: Some(1) },
                ..
            } if label == "virtiofsd-workspace"
        ));
    }

    #[test]
    fn wait_for_qemu_leaves_sidecars_for_drop_cleanup() {
        let temp = TestDir::new("wait");
        let plan = sample_plan(temp.path());
        let spawner = FakeSpawner::new()
            .with_socket_creation(true)
            .with_exited_label("qemu");
        let state = spawner.state.clone();
        let mut supervisor = Supervisor::with_spawner(spawner, fast_options());

        let mut vm = supervisor.launch_plan(&plan).unwrap();
        let status = vm.wait_for_qemu().unwrap();

        assert_eq!(status, ProcessExit { code: Some(1) });
        drop(vm);

        let state = state.borrow();
        let qemu = state
            .children
            .iter()
            .find(|child| child.borrow().label == "qemu")
            .unwrap();
        assert!(!qemu.borrow().killed);
        assert!(qemu.borrow().waited);
        let sidecars = state
            .children
            .iter()
            .filter(|child| child.borrow().label.starts_with("virtiofsd-"));
        assert!(sidecars.into_iter().all(|child| child.borrow().killed));
    }

    #[test]
    fn stop_run_dir_terminates_recorded_processes_and_removes_pid_files() {
        let temp = TestDir::new("stop");
        let mut child = Command::new("/bin/sh")
            .arg("-lc")
            .arg("sleep 60")
            .spawn()
            .unwrap();
        fs::write(temp.path().join("qemu.pid"), format!("{}\n", child.id())).unwrap();

        let report = stop_run_dir(temp.path(), Duration::ZERO).unwrap();

        assert_eq!(report.terminated, vec!["qemu".to_string()]);
        assert!(report.stale.is_empty());
        assert!(!temp.path().join("qemu.pid").exists());

        let status = child.wait().unwrap();
        assert!(!status.success());
    }

    fn sample_plan(root: &Path) -> LaunchPlan {
        fs::create_dir_all(root.join("workspace")).unwrap();
        let mut config = LaunchConfig::new(
            RuntimeArtifacts::from_runtime_dir(root.join("runtime")),
            root.join("workspace"),
            root.join("cache"),
            root.join("tools"),
            root.join("run"),
            123,
        );
        config.network = NetworkMode::Off;
        build_launch_plan(&config).unwrap()
    }

    fn fast_options() -> SupervisorOptions {
        SupervisorOptions {
            socket_timeout: Duration::ZERO,
            poll_interval: Duration::ZERO,
            qemu_io: ProcessIo::Inherit,
        }
    }

    struct TestDir {
        path: PathBuf,
    }

    impl TestDir {
        fn new(name: &str) -> Self {
            let id = TEST_COUNTER.fetch_add(1, Ordering::SeqCst);
            let path = PathBuf::from("/tmp").join(format!(
                "fend-linux-supervisor-{name}-{}-{id}",
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

    #[derive(Clone)]
    struct FakeSpawner {
        state: Rc<RefCell<FakeState>>,
    }

    impl FakeSpawner {
        fn new() -> Self {
            Self {
                state: Rc::new(RefCell::new(FakeState::default())),
            }
        }

        fn with_socket_creation(self, create_sockets: bool) -> Self {
            self.state.borrow_mut().create_sockets = create_sockets;
            self
        }

        fn with_failed_program(self, program: &str) -> Self {
            self.state.borrow_mut().failed_program = Some(program.to_string());
            self
        }

        fn with_exited_label(self, label: &str) -> Self {
            self.state
                .borrow_mut()
                .exited_labels
                .insert(label.to_string());
            self
        }
    }

    #[derive(Default)]
    struct FakeState {
        calls: Vec<ProcessSpec>,
        children: Vec<Rc<RefCell<FakeChildState>>>,
        next_id: u32,
        create_sockets: bool,
        failed_program: Option<String>,
        exited_labels: HashSet<String>,
    }

    impl ProcessSpawner for FakeSpawner {
        type Child = FakeChild;

        fn spawn(&mut self, spec: &ProcessSpec) -> io::Result<Self::Child> {
            let mut state = self.state.borrow_mut();
            state.calls.push(spec.clone());
            if state.failed_program.as_deref() == Some(spec.program.as_str()) {
                return Err(io::Error::new(
                    io::ErrorKind::NotFound,
                    "missing fake program",
                ));
            }

            if state.create_sockets && spec.label.starts_with("virtiofsd-") {
                let socket = spec
                    .args
                    .iter()
                    .find_map(|arg| arg.strip_prefix("--socket-path="))
                    .expect("virtiofsd socket path");
                fs::write(socket, b"fake socket").unwrap();
            }

            state.next_id += 1;
            let child = Rc::new(RefCell::new(FakeChildState {
                id: state.next_id,
                label: spec.label.clone(),
                exited: state.exited_labels.contains(&spec.label),
                killed: false,
                waited: false,
            }));
            state.children.push(child.clone());
            Ok(FakeChild { state: child })
        }
    }

    #[derive(Debug)]
    struct FakeChild {
        state: Rc<RefCell<FakeChildState>>,
    }

    #[derive(Debug)]
    struct FakeChildState {
        id: u32,
        label: String,
        exited: bool,
        killed: bool,
        waited: bool,
    }

    impl ManagedChild for FakeChild {
        fn id(&self) -> u32 {
            self.state.borrow().id
        }

        fn try_wait(&mut self) -> io::Result<Option<ProcessExit>> {
            if self.state.borrow().exited {
                Ok(Some(ProcessExit { code: Some(1) }))
            } else {
                Ok(None)
            }
        }

        fn kill(&mut self) -> io::Result<()> {
            let mut state = self.state.borrow_mut();
            state.killed = true;
            state.exited = true;
            Ok(())
        }

        fn wait(&mut self) -> io::Result<ProcessExit> {
            let mut state = self.state.borrow_mut();
            state.waited = true;
            state.exited = true;
            Ok(ProcessExit { code: Some(1) })
        }
    }
}
