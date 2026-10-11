use crate::{
    config::{self, Config},
    engine::Engine,
    store::Store,
};
use anyhow::{Context, Result};
use evdev::{raw_stream::RawDevice as Device, EventType, KeyCode};
use serde::Serialize;
use std::{
    collections::{HashMap, HashSet},
    fs,
    io::{Read, Write},
    os::unix::{io::AsRawFd, net::UnixStream},
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use zbus::{
    blocking::{Connection, Proxy},
    zvariant::OwnedObjectPath,
};
#[derive(Default, Serialize)]
pub struct Status {
    pub running: bool,
    pub paused: bool,
    pub reason: String,
    pub devices: Vec<String>,
    pub input_mode: String,
    pub updated: i64,
}
struct Keyboard {
    dev: Device,
    id: String,
    name: String,
}
fn epoch() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}
fn hypr_socket() -> Result<PathBuf> {
    Ok(PathBuf::from(std::env::var("XDG_RUNTIME_DIR")?)
        .join("hypr")
        .join(std::env::var("HYPRLAND_INSTANCE_SIGNATURE")?)
        .join(".socket.sock"))
}
fn active_app() -> Result<String> {
    let mut socket = UnixStream::connect(hypr_socket()?)?;
    socket.set_read_timeout(Some(Duration::from_millis(200)))?;
    socket.set_write_timeout(Some(Duration::from_millis(200)))?;
    socket.write_all(b"j/activewindow")?;
    let mut buf = String::new();
    socket.take(65536).read_to_string(&mut buf)?;
    let value: serde_json::Value = serde_json::from_str(&buf)?;
    Ok(value
        .get("class")
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty())
        .unwrap_or("desktop")
        .chars()
        .take(256)
        .collect())
}
fn lock_process_exists() -> bool {
    // Hyprlock can acquire the Wayland session lock before logind's LockedHint changes.
    fs::read_dir("/proc")
        .map(|entries| {
            entries.flatten().any(|e| {
                fs::read_to_string(e.path().join("comm")).is_ok_and(|s| s.trim() == "hyprlock")
            })
        })
        .unwrap_or(true)
}
// Bind to the compositor's logind session, never to an arbitrary same-user TTY.
fn compositor_session(bus: &Connection) -> Result<OwnedObjectPath> {
    let socket = UnixStream::connect(hypr_socket()?)?;
    let mut cred: libc::ucred = unsafe { std::mem::zeroed() };
    let mut len = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    anyhow::ensure!(
        unsafe {
            libc::getsockopt(
                socket.as_raw_fd(),
                libc::SOL_SOCKET,
                libc::SO_PEERCRED,
                (&mut cred as *mut libc::ucred).cast(),
                &mut len,
            )
        } == 0,
        "cannot identify compositor"
    );
    anyhow::ensure!(
        cred.uid == unsafe { libc::getuid() } && cred.pid > 0,
        "unexpected compositor peer"
    );
    let manager = Proxy::new(
        bus,
        "org.freedesktop.login1",
        "/org/freedesktop/login1",
        "org.freedesktop.login1.Manager",
    )?;
    Ok(manager.call("GetSessionByPID", &(cred.pid as u32,))?)
}
fn session_allowed(bus: &Connection, path: &OwnedObjectPath) -> Result<bool> {
    let session = Proxy::new(
        bus,
        "org.freedesktop.login1",
        path.clone(),
        "org.freedesktop.login1.Session",
    )?;
    Ok(session.get_property::<bool>("Active")? && !session.get_property::<bool>("LockedHint")?)
}
// Focus notifications catch a switch away and back between polling boundaries.
// Payloads (including titles from unrelated events) are discarded, never logged.
struct FocusEvents {
    socket: UnixStream,
    tail: Vec<u8>,
}
impl FocusEvents {
    fn connect() -> Result<Self> {
        let socket = UnixStream::connect(hypr_socket()?.with_file_name(".socket2.sock"))?;
        socket.set_nonblocking(true)?;
        Ok(Self {
            socket,
            tail: vec![],
        })
    }
    fn changed(&mut self) -> Result<bool> {
        let mut changed = false;
        let mut buf = [0; 4096];
        loop {
            match self.socket.read(&mut buf) {
                Ok(0) => anyhow::bail!("Hyprland event stream closed"),
                Ok(n) => {
                    self.tail.extend_from_slice(&buf[..n]);
                    anyhow::ensure!(self.tail.len() < 262144, "Hyprland event overflow");
                    while let Some(end) = self.tail.iter().position(|b| *b == b'\n') {
                        let line = &self.tail[..end];
                        if [
                            b"activewindowv2>>".as_slice(),
                            b"focusedmon>>",
                            b"openlayer>>",
                            b"closelayer>>",
                            b"configreloaded>>",
                        ]
                        .iter()
                        .any(|prefix| line.starts_with(prefix))
                        {
                            changed = true;
                        }
                        self.tail.drain(..=end);
                    }
                }
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => break,
                Err(e) => return Err(e.into()),
            }
        }
        Ok(changed)
    }
}
fn resync(engine: &mut Engine, devices: &HashMap<PathBuf, Keyboard>) {
    engine.reset();
    for k in devices.values() {
        if let Ok(state) = k.dev.get_key_state() {
            engine.sync_down(&k.id, state.iter().map(|k| k.code()));
        }
    }
}
fn scan(config: &Config) -> Vec<(PathBuf, Device, String, String)> {
    let mut found = vec![];
    let Ok(entries) = fs::read_dir("/dev/input") else {
        return found;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if !entry.file_name().to_string_lossy().starts_with("event") {
            continue;
        }
        let Ok(dev) = Device::open(&path) else {
            continue;
        };
        let name = dev.name().unwrap_or("Keyboard").to_owned();
        if config
            .excluded_devices
            .iter()
            .any(|s| name.to_lowercase().contains(&s.to_lowercase()))
        {
            continue;
        }
        if !dev
            .supported_keys()
            .is_some_and(|k| k.contains(KeyCode::KEY_A) && k.contains(KeyCode::KEY_ENTER))
        {
            continue;
        }
        let Some(file) = path.file_name() else {
            continue;
        };
        let physical =
            fs::canonicalize(PathBuf::from("/sys/class/input").join(file).join("device"))
                .is_ok_and(|p| !p.to_string_lossy().contains("/virtual/"));
        if !physical && name != "xremap" {
            continue;
        }
        let id = if name == "xremap" {
            "xremap (combined)".into()
        } else {
            format!(
                "{} [{:04x}:{:04x}:{}]",
                name,
                dev.input_id().vendor(),
                dev.input_id().product(),
                dev.physical_path().unwrap_or("unknown")
            )
        };
        found.push((path, dev, id, name));
    }
    let use_xremap = config.input_mode == "xremap"
        || (config.input_mode == "auto" && found.iter().any(|v| v.3 == "xremap"));
    found.retain(|v| {
        if use_xremap {
            v.3 == "xremap"
        } else {
            v.3 != "xremap"
        }
    });
    found
}
pub fn run(path: &std::path::Path) -> Result<()> {
    let runtime = config::runtime_dir();
    fs::create_dir_all(&runtime)?;
    let lock = fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(runtime.join("daemon.lock"))?;
    anyhow::ensure!(
        unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0,
        "daemon already running"
    );
    let mut store = Store::open(path)?;
    let mut engine = Engine::default();
    let mut devices: HashMap<PathBuf, Keyboard> = HashMap::new();
    let stop = Arc::new(AtomicBool::new(false));
    signal_hook::flag::register(signal_hook::consts::SIGTERM, stop.clone())?;
    signal_hook::flag::register(signal_hook::consts::SIGINT, stop.clone())?;
    let bus = Connection::system().context("logind is required for active-session/lock checks")?;
    let session = compositor_session(&bus)?;
    let mut focus = FocusEvents::connect()?;
    let mut config = Config::load()?;
    let mut records = vec![];
    let mut times = vec![];
    let mut pending: Vec<(String, u16, i32, Duration)> = vec![];
    let mut last_scan = Instant::now() - Duration::from_secs(10);
    let mut last_context = last_scan;
    let mut last_flush = last_scan;
    let mut current_app = String::new();
    let mut allowed = false;
    let mut reason = String::new();
    let mut last_input = Instant::now() - Duration::from_secs(120);
    let mut invalidated = true;
    let mut boundary = SystemTime::now();
    eprintln!("KeyStats collector started (aggregates only)");
    while !stop.load(Ordering::Relaxed) {
        let now = Instant::now();
        let drain_boundary = SystemTime::now();
        if last_scan.elapsed() >= Duration::from_secs(2) {
            let found = scan(&config);
            let paths: HashSet<_> = found.iter().map(|v| v.0.clone()).collect();
            devices.retain(|p, _| {
                if !paths.contains(p) {
                    invalidated = true;
                    false
                } else {
                    true
                }
            });
            for (p, d, id, name) in found {
                if let std::collections::hash_map::Entry::Vacant(v) = devices.entry(p) {
                    let flags = unsafe { libc::fcntl(d.as_raw_fd(), libc::F_GETFL) };
                    anyhow::ensure!(
                        flags >= 0
                            && unsafe {
                                libc::fcntl(d.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK)
                            } >= 0,
                        "cannot set evdev nonblocking"
                    );
                    v.insert(Keyboard { dev: d, id, name });
                    invalidated = true;
                }
            }
            last_scan = now;
        }
        invalidated |= focus.changed()? || config::paused();
        let mut dead = vec![];
        for (p, k) in devices.iter_mut() {
            match k.dev.fetch_events() {
                Ok(events) => {
                    for ev in events {
                        // Raw evdev prevents SYN_DROPPED recovery from inventing presses.
                        if ev.event_type() == EventType::SYNCHRONIZATION && ev.code() == 3 {
                            invalidated = true;
                        }
                        if !allowed || invalidated || ev.event_type() != EventType::KEY {
                            continue;
                        }
                        if ev.timestamp() < boundary {
                            continue;
                        }
                        if let Ok(wall) = ev.timestamp().duration_since(UNIX_EPOCH) {
                            pending.push((k.id.clone(), ev.code(), ev.value(), wall));
                        }
                        if pending.len() > 4096 {
                            invalidated = true;
                            pending.clear();
                        }
                    }
                }
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
                Err(_) => dead.push(p.clone()),
            }
        }
        for p in dead {
            devices.remove(&p);
            invalidated = true;
        }
        if last_context.elapsed() >= Duration::from_millis(200) {
            let previous_app = current_app.clone();
            let previously_allowed = allowed;
            let config_valid = match Config::load() {
                Ok(c) => {
                    if c != config {
                        invalidated = true;
                        last_scan = now - Duration::from_secs(10);
                    }
                    config = c;
                    true
                }
                Err(_) => false,
            };
            let session_ok =
                session_allowed(&bus, &session).unwrap_or(false) && !lock_process_exists();
            let app = active_app();
            reason = if !config_valid {
                "Invalid configuration"
            } else if config::paused() {
                "Paused"
            } else if !session_ok {
                "Locked or inactive session"
            } else if app.is_err() {
                "Hyprland unavailable"
            } else {
                ""
            }
            .into();
            current_app = app.unwrap_or_default();
            if reason.is_empty() && config.excludes(&current_app) {
                reason = "Excluded application".into();
            }
            if devices.is_empty() && reason.is_empty() {
                reason = "No readable keyboard — check seat ACL".into();
            }
            allowed = reason.is_empty();
            invalidated |= focus.changed()?;
            // Confirm both ends of the sampling interval BEFORE converting input to records.
            if crate::engine::stable_interval(
                previously_allowed,
                allowed,
                &previous_app,
                &current_app,
                invalidated,
            ) {
                pending.sort_by_key(|e| e.3);
                for (device, key, value, wall) in pending.drain(..) {
                    if value == 1 {
                        last_input = now;
                    }
                    if let Some(r) = engine.event(
                        key,
                        value,
                        &device,
                        &current_app,
                        wall.as_secs_f64(),
                        wall.as_secs() as i64,
                    ) {
                        records.push(r);
                    }
                }
                if last_input.elapsed() < Duration::from_secs(60) {
                    times.push((
                        epoch() / 3600,
                        current_app.clone(),
                        last_context.elapsed().as_millis().min(1000) as i64,
                    ));
                }
            } else {
                pending.clear();
                resync(&mut engine, &devices);
            }
            // Keep events arriving DURING IPC for the next interval, especially releases.
            // Advancing to gate completion would strand held keys in Engine.down.
            boundary = drain_boundary;
            last_context = now;
            invalidated = false;
        }
        if last_flush.elapsed() >= Duration::from_secs(2) || records.len() >= 256 {
            store.flush(&records, &times)?;
            records.clear();
            times.clear();
            config::atomic_json(
                &runtime.join("status.json"),
                &Status {
                    running: true,
                    paused: config::paused(),
                    reason: reason.clone(),
                    devices: devices.values().map(|k| k.name.clone()).collect(),
                    input_mode: config.input_mode.clone(),
                    updated: epoch(),
                },
            )?;
            last_flush = now;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    // Unconfirmed input is intentionally discarded on shutdown.
    store.flush(&records, &times)?;
    config::atomic_json(
        &runtime.join("status.json"),
        &Status {
            reason: "Stopped".into(),
            updated: epoch(),
            ..Default::default()
        },
    )?;
    Ok(())
}
