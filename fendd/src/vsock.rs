use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};

/// AF_VSOCK address family (Linux).
const AF_VSOCK: libc::c_int = 40;

/// Bind to any CID (the VM's own CID).
const VMADDR_CID_ANY: u32 = 0xFFFFFFFF;

#[repr(C)]
struct SockaddrVm {
    svm_family: libc::sa_family_t,
    svm_reserved1: u16,
    svm_port: u32,
    svm_cid: u32,
    svm_flags: u8,
    svm_zero: [u8; 3],
}

// ── VsockListener ───────────────────────────────────────────────────

pub struct VsockListener {
    fd: OwnedFd,
}

impl VsockListener {
    pub fn bind(port: u32) -> io::Result<Self> {
        let fd = unsafe { libc::socket(AF_VSOCK, libc::SOCK_STREAM, 0) };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        let fd = unsafe { OwnedFd::from_raw_fd(fd) };

        let addr = SockaddrVm {
            svm_family: AF_VSOCK as libc::sa_family_t,
            svm_reserved1: 0,
            svm_port: port,
            svm_cid: VMADDR_CID_ANY,
            svm_flags: 0,
            svm_zero: [0; 3],
        };

        let ret = unsafe {
            libc::bind(
                fd.as_raw_fd(),
                &addr as *const SockaddrVm as *const libc::sockaddr,
                std::mem::size_of::<SockaddrVm>() as libc::socklen_t,
            )
        };
        if ret < 0 {
            return Err(io::Error::last_os_error());
        }

        let ret = unsafe { libc::listen(fd.as_raw_fd(), 8) };
        if ret < 0 {
            return Err(io::Error::last_os_error());
        }

        Ok(VsockListener { fd })
    }

    pub fn accept(&self) -> io::Result<VsockStream> {
        let client_fd = unsafe {
            libc::accept(self.fd.as_raw_fd(), std::ptr::null_mut(), std::ptr::null_mut())
        };
        if client_fd < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(VsockStream {
            fd: unsafe { OwnedFd::from_raw_fd(client_fd) },
        })
    }
}

// ── VsockStream ─────────────────────────────────────────────────────

pub struct VsockStream {
    fd: OwnedFd,
}

impl VsockStream {
    pub fn try_clone(&self) -> io::Result<Self> {
        let new_fd = unsafe { libc::dup(self.fd.as_raw_fd()) };
        if new_fd < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(VsockStream {
            fd: unsafe { OwnedFd::from_raw_fd(new_fd) },
        })
    }
}

impl AsRawFd for VsockStream {
    fn as_raw_fd(&self) -> RawFd {
        self.fd.as_raw_fd()
    }
}

impl Read for VsockStream {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let n = unsafe { libc::read(self.fd.as_raw_fd(), buf.as_mut_ptr() as *mut _, buf.len()) };
        if n < 0 {
            Err(io::Error::last_os_error())
        } else {
            Ok(n as usize)
        }
    }
}

impl Write for VsockStream {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        let n = unsafe { libc::write(self.fd.as_raw_fd(), buf.as_ptr() as *const _, buf.len()) };
        if n < 0 {
            Err(io::Error::last_os_error())
        } else {
            Ok(n as usize)
        }
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}
