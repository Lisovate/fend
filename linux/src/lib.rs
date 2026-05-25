//! Linux host backend for fend.
//!
//! This crate is currently a host-side implementation spike. It builds QEMU
//! launch plans, checks Linux/KVM prerequisites, supervises helper processes,
//! and verifies guest command execution over vsock.

pub mod app;
pub mod bootstrap;
pub mod cli;
pub mod client;
pub mod daemon;
pub mod doctor;
pub mod ipc;
pub mod pool;
pub mod qemu;
pub mod runtime;
pub mod session;
pub mod smoke;
pub mod supervisor;
pub mod tools;
