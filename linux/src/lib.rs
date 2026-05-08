//! Linux host backend for fend.
//!
//! This crate is currently a host-side implementation spike. It builds QEMU
//! launch plans, checks Linux/KVM prerequisites, supervises helper processes,
//! and verifies guest command execution over vsock.

pub mod app;
pub mod cli;
pub mod doctor;
pub mod qemu;
pub mod smoke;
pub mod supervisor;
pub mod tools;
