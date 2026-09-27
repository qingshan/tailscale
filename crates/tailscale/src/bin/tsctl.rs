//! LIPC service `dev.qingshan.tsctl`.
//!
//! `runCMD` runs its value with `sh -c` and caches stdout. The WAF uses that
//! because kindle.messaging has no synchronous result. `exit` stops the
//! process. `info` returns the build stamps.
//!
//! Default mode double-forks. `-n` stays in the foreground for upstart.
//! Callbacks must not unwind across the C boundary (a poisoned mutex is
//! recovered, not unwrapped).

use std::ffi::{c_char, c_int, c_void, CStr};
use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, MutexGuard};
use std::time::Duration;

use tailscale::lipc::{
    read_string_prop, write_string_prop, LIPC_ERROR_DUPLICATE_SERVICE_NAME, LIPC_ERROR_INVALID_ARG,
    LIPC_OK,
};

const SERVICE_NAME: &CStr = c"dev.qingshan.tsctl";

type LipcHandle = *mut c_void;
type LipcCallback = extern "C" fn(LipcHandle, *const c_char, *mut c_void, *mut c_void) -> c_int;

// liblipc.so.1 ships with every Kindle firmware; the cross toolchain resolves it from its
// own sysroot at link time.
#[link(name = "lipc")]
extern "C" {
    fn LipcOpenEx(service: *const c_char, code: *mut c_int) -> LipcHandle;
    fn LipcClose(handle: LipcHandle) -> c_int;
    fn LipcRegisterStringProperty(
        lipc: LipcHandle,
        prop: *const c_char,
        getter: Option<LipcCallback>,
        setter: Option<LipcCallback>,
        data: *mut c_void,
    ) -> c_int;
}

static KEEP_RUNNING: AtomicBool = AtomicBool::new(true);
static LAST_OUTPUT: Mutex<Option<String>> = Mutex::new(None);

/// Lock the last-output cache, recovering from poisoning instead of panicking (a panic in a
/// callback would unwind through C frames).
fn last_output() -> MutexGuard<'static, Option<String>> {
    LAST_OUTPUT
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

// --- runCMD ----------------------------------------------------------------
// Setter executes `sh -c <value>` and caches stdout; getter returns it (same protocol as
// utild, which only captures stdout via popen).

extern "C" fn runcmd_getter(
    _h: LipcHandle,
    _p: *const c_char,
    value: *mut c_void,
    data: *mut c_void,
) -> c_int {
    let out = last_output();
    unsafe { write_string_prop(value, data, out.as_deref().unwrap_or("No output yet.")) }
}

extern "C" fn runcmd_setter(
    _h: LipcHandle,
    _p: *const c_char,
    value: *mut c_void,
    _d: *mut c_void,
) -> c_int {
    let Some(cmd) = (unsafe { read_string_prop(value) }) else {
        return LIPC_ERROR_INVALID_ARG;
    };
    let out = Command::new("sh")
        .arg("-c")
        .arg(&cmd)
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_default();
    *last_output() = Some(out);
    LIPC_OK
}

// --- exit ------------------------------------------------------------------

extern "C" fn exit_getter(
    _h: LipcHandle,
    _p: *const c_char,
    value: *mut c_void,
    data: *mut c_void,
) -> c_int {
    unsafe { write_string_prop(value, data, "Write into this property to exit tsctl") }
}

extern "C" fn exit_setter(
    _h: LipcHandle,
    _p: *const c_char,
    _value: *mut c_void,
    _d: *mut c_void,
) -> c_int {
    KEEP_RUNNING.store(false, Ordering::SeqCst);
    LIPC_OK
}

// --- info ------------------------------------------------------------------

extern "C" fn info_getter(
    _h: LipcHandle,
    _p: *const c_char,
    value: *mut c_void,
    data: *mut c_void,
) -> c_int {
    let msg = format!(
        "Build Info: Branch: {}, Commit: {}, Built On: {}",
        env!("GIT_BRANCH"),
        env!("GIT_COMMIT"),
        env!("BUILD_TIME")
    );
    unsafe { write_string_prop(value, data, &msg) }
}

// Double-fork. Reopen 0/1/2 onto /dev/null: the next socket would otherwise
// reuse fd 0 and later writes would land on the LIPC connection. Leave
// SIGCHLD alone so `Command::output` can wait; ignoring it makes waitpid
// return ECHILD and the captured stdout is dropped. umask 022 so files
// created from runCMD are not world-writable on /var.

fn daemonize() {
    unsafe {
        let pid = libc::fork();
        if pid < 0 || pid > 0 {
            std::process::exit(if pid < 0 { 1 } else { 0 });
        }
        if libc::setsid() < 0 {
            std::process::exit(1);
        }
        libc::signal(libc::SIGHUP, libc::SIG_IGN);
        let pid = libc::fork();
        if pid < 0 || pid > 0 {
            std::process::exit(if pid < 0 { 1 } else { 0 });
        }
        libc::umask(0o022);
        if libc::chdir(c"/mnt/us/tailscale".as_ptr()) != 0 {
            std::process::exit(1);
        }
        let devnull = libc::open(c"/dev/null".as_ptr(), libc::O_RDWR);
        if devnull >= 0 {
            libc::dup2(devnull, 0);
            libc::dup2(devnull, 1);
            libc::dup2(devnull, 2);
            if devnull > 2 {
                libc::close(devnull);
            }
        }
        let mut max_fd: i64 = 1024;
        let mut rlim = libc::rlimit {
            rlim_cur: 0,
            rlim_max: 0,
        };
        if libc::getrlimit(libc::RLIMIT_NOFILE, &mut rlim) == 0 && rlim.rlim_cur > 3 {
            let cur = rlim.rlim_cur as u64;
            if cur < 4096 {
                max_fd = cur as i64;
            } else {
                max_fd = 4096;
            }
        }
        let mut fd = 3i64;
        while fd < max_fd {
            libc::close(fd as c_int);
            fd += 1;
        }
    }
}

extern "C" fn handle_signal(_sig: c_int) {
    KEEP_RUNNING.store(false, Ordering::SeqCst);
}

// --- main ------------------------------------------------------------------

fn main() {
    let run_as_daemon = !std::env::args()
        .skip(1)
        .any(|a| a == "-n" || a == "--no-daemon");
    if run_as_daemon {
        println!("Forking into the background.");
        daemonize();
    } else {
        println!("Running in foreground mode.");
        unsafe {
            libc::signal(
                libc::SIGINT,
                handle_signal as *const () as libc::sighandler_t,
            );
            libc::signal(
                libc::SIGTERM,
                handle_signal as *const () as libc::sighandler_t,
            );
        }
    }

    let mut code: c_int = -1;
    let handle = unsafe { LipcOpenEx(SERVICE_NAME.as_ptr(), &mut code) };
    if code != LIPC_OK {
        if code == LIPC_ERROR_DUPLICATE_SERVICE_NAME {
            // Another tsctl instance already owns this service - it's
            // serving the WAF, so starting again is a no-op, not an error.
            return;
        }
        eprintln!("Failed to open LIPC (code {code})");
        std::process::exit(1);
    }

    let props: [(&CStr, Option<LipcCallback>, Option<LipcCallback>); 3] = [
        (c"runCMD", Some(runcmd_getter), Some(runcmd_setter)),
        (c"exit", Some(exit_getter), Some(exit_setter)),
        (c"info", Some(info_getter), None),
    ];
    for (prop, getter, setter) in props {
        unsafe {
            LipcRegisterStringProperty(handle, prop.as_ptr(), getter, setter, std::ptr::null_mut())
        };
    }

    while KEEP_RUNNING.load(Ordering::SeqCst) {
        std::thread::sleep(Duration::from_secs(1));
    }

    unsafe { LipcClose(handle) };
    println!("tsctl shutting down.");
}
