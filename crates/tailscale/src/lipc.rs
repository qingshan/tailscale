//! Pure helpers for the tsctl LIPC daemon.
//!
//! This module deliberately contains no FFI declarations or `#[link]` attributes so the
//! string-buffer convention can be unit-tested on the host (`cargo test --lib`).
//!
//! Callback convention (verified against utild's StringHandler.h and openlipc's
//! lipc-test-prop.c): liblipc calls string-property callbacks as
//! `fn(lipc, property, value, data)` where for a GETTER `value` is the output
//! `char*` buffer and `data` points to a `size_t` holding its capacity, and for a
//! SETTER `value` is the NUL-terminated input string. `value` is NEVER a pointer
//! to a wrapper struct.

use std::ffi::{c_char, c_int, c_void};

// LIPCcode values (from lipc.h)
pub const LIPC_OK: c_int = 0;
pub const LIPC_ERROR_INTERNAL: c_int = 2;
pub const LIPC_ERROR_BUFFER_TOO_SMALL: c_int = 10;
pub const LIPC_ERROR_INVALID_ARG: c_int = 12;
pub const LIPC_ERROR_DUPLICATE_SERVICE_NAME: c_int = 17;

/// Copy `s` into the caller's buffer (getter path).
///
/// `value` is the output buffer, `data` points to the capacity. Returns
/// [`LIPC_ERROR_BUFFER_TOO_SMALL`] and stores the needed size in `capacity` when the
/// buffer is too small — the same convention as utild's `LIPCString::set`, so liblipc
/// clients (lipc-get-prop et al.) retry with a bigger buffer and then succeed.
///
/// # Safety
/// `value` must point to a writable buffer of at least `capacity` bytes and
/// `data` must point to a `size_t` holding that capacity.
pub unsafe fn write_string_prop(value: *mut c_void, data: *mut c_void, s: &str) -> c_int {
    let buf = value as *mut c_char;
    let capacity = &mut *(data as *mut usize);
    let needed = s.len() + 1;
    if needed > *capacity {
        *capacity = needed;
        return LIPC_ERROR_BUFFER_TOO_SMALL;
    }
    // SAFETY: caller-provided buffer of at least `needed` bytes, s is valid for `needed` bytes.
    // Copy s.len() bytes, then write the NUL explicitly — the byte after a &str is not
    // guaranteed to be readable (adjacent literals get merged without interior NULs).
    unsafe {
        std::ptr::copy_nonoverlapping(s.as_ptr(), buf as *mut u8, s.len());
        *buf.add(s.len()) = 0;
    };
    LIPC_OK
}

/// Read the caller-provided input string (setter path). Returns `None` on a null buffer.
///
/// # Safety
/// `value` must point to a NUL-terminated C string (or be null).
pub unsafe fn read_string_prop(value: *mut c_void) -> Option<String> {
    if value.is_null() {
        return None;
    }
    // SAFETY: caller-provided NUL-terminated buffer.
    Some(
        unsafe { std::ffi::CStr::from_ptr(value as *const c_char) }
            .to_string_lossy()
            .into_owned(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fits_exactly() {
        let mut cap = 6usize;
        let mut buf = [0u8; 6];
        let rc = unsafe {
            write_string_prop(
                buf.as_mut_ptr() as *mut c_void,
                &mut cap as *mut usize as *mut c_void,
                "hello",
            )
        };
        assert_eq!(rc, LIPC_OK);
        assert_eq!(&buf, b"hello\0");
    }

    #[test]
    fn too_small_reports_needed_size() {
        let mut cap = 3usize;
        let mut buf = [0u8; 3];
        let rc = unsafe {
            write_string_prop(
                buf.as_mut_ptr() as *mut c_void,
                &mut cap as *mut usize as *mut c_void,
                "hello",
            )
        };
        assert_eq!(rc, LIPC_ERROR_BUFFER_TOO_SMALL);
        assert_eq!(cap, 6, "capacity must be updated so the client can retry");
    }

    #[test]
    fn read_input_string() {
        let mut buf = *b"ls\0";
        assert_eq!(
            unsafe { read_string_prop(buf.as_mut_ptr() as *mut c_void) },
            Some("ls".to_string())
        );
    }
}
