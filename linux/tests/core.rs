use keystats_linux::{
    config::Config,
    engine::Engine,
    keys,
    store::{import_macos, Filter, Store},
};
fn press(e: &mut Engine, k: u16, t: f64, app: &str) -> keystats_linux::engine::Record {
    let r = e
        .event(k, 1, "keyboard", app, t, 360000 + t as i64)
        .unwrap();
    e.event(k, 0, "keyboard", app, t + 0.01, 360000 + t as i64);
    r
}
#[test]
fn physical_press_repeat_and_release() {
    let mut e = Engine::default();
    assert!(e.event(30, 1, "a", "editor", 1.0, 3600).is_some());
    assert!(e.event(30, 2, "a", "editor", 1.1, 3600).is_none());
    assert!(e.event(30, 1, "a", "editor", 1.2, 3600).is_none());
    assert!(e.event(30, 0, "a", "editor", 1.3, 3600).is_none());
    assert!(e.event(30, 1, "a", "editor", 1.4, 3600).is_some());
}
#[test]
fn left_right_modifiers_and_shortcuts() {
    let mut e = Engine::default();
    e.event(29, 1, "a", "editor", 1.0, 3600);
    e.event(97, 1, "a", "editor", 1.1, 3600);
    e.event(29, 0, "a", "editor", 1.2, 3600);
    assert_eq!(
        e.event(46, 1, "a", "editor", 1.3, 3600)
            .unwrap()
            .combo
            .as_deref(),
        Some("Ctrl+C")
    );
    e.release_device("a");
    assert_eq!(
        e.event(46, 1, "a", "editor", 1.4, 3600).unwrap().combo,
        None
    );
}
#[test]
fn weak_keys_decay_and_expire() {
    let mut e = Engine::default();
    press(&mut e, 30, 1.0, "editor");
    press(&mut e, 31, 1.4, "editor");
    let r = press(&mut e, 14, 1.7, "editor");
    assert_eq!(r.weights, vec![(31, 1.0), (30, 0.5)]);
    assert!(r.correction);
    assert_eq!(r.speed_keys, 0);
    assert!(press(&mut e, 14, 5.0, "editor").weights.is_empty());
}
#[test]
fn weak_keys_not_cross_application() {
    let mut e = Engine::default();
    press(&mut e, 30, 1.0, "editor");
    let r = press(&mut e, 14, 1.2, "browser");
    assert!(r.weights.is_empty());
    let r = press(&mut e, 31, 1.3, "editor");
    assert_eq!(r.active_ms, 0);
}
#[test]
fn reset_on_pause_drops_pending_context() {
    let mut e = Engine::default();
    press(&mut e, 30, 1.0, "editor");
    e.reset();
    let r = press(&mut e, 14, 1.2, "editor");
    assert!(r.weights.is_empty());
}
#[test]
fn peak_requires_sustained_typing() {
    let mut e = Engine::default();
    let mut peak = 0;
    for i in 0..5 {
        peak = peak.max(press(&mut e, 30, 1.0 + i as f64 * 0.1, "editor").peak_kpm)
    }
    assert_eq!(peak, 0);
    e.reset();
    for i in 0..6 {
        peak = peak.max(press(&mut e, 30, 1.0 + i as f64 * 0.5, "editor").peak_kpm)
    }
    assert!(peak >= 120 && peak <= 150);
}
#[test]
fn hour_boundary_does_not_leak_speed() {
    let mut e = Engine::default();
    e.event(30, 1, "a", "editor", 1.0, 3599);
    e.event(30, 0, "a", "editor", 1.1, 3599);
    assert_eq!(
        e.event(30, 1, "a", "editor", 1.5, 3600).unwrap().active_ms,
        0
    );
}
#[test]
fn store_filters_and_read_only_reader() {
    let d = tempfile::tempdir().unwrap();
    let p = d.path().join("test.db");
    let mut s = Store::open(&p).unwrap();
    let mut e = Engine::default();
    let records = vec![
        press(&mut e, 30, 1.0, "app'one"),
        press(&mut e, 30, 1.5, "app'one"),
        press(&mut e, 31, 2.0, "app-two"),
    ];
    s.flush(&records, &[(100, "app'one".into(), 1500)]).unwrap();
    let reader = Store::read(&p).unwrap();
    assert_eq!(reader.snapshot(&Filter::default()).unwrap().total, 3);
    let f = Filter {
        app: Some("app'one".into()),
        ..Default::default()
    };
    assert_eq!(reader.snapshot(&f).unwrap().total, 2);
    assert_eq!(
        reader
            .snapshot(&Filter {
                key: Some(30),
                ..Default::default()
            })
            .unwrap()
            .total,
        2
    );
    assert_eq!(
        reader
            .snapshot(&Filter {
                since: 101,
                ..Default::default()
            })
            .unwrap()
            .total,
        0
    );
    assert!(reader.conn.execute("DELETE FROM counts", []).is_err());
}
#[test]
fn no_raw_event_tables() {
    let d = tempfile::tempdir().unwrap();
    let s = Store::open(&d.path().join("test.db")).unwrap();
    let tables: Vec<String> = s
        .conn
        .prepare("SELECT name FROM sqlite_master WHERE type='table'")
        .unwrap()
        .query_map([], |r| r.get(0))
        .unwrap()
        .map(Result::unwrap)
        .collect();
    assert_eq!(tables.len(), 6);
    assert!(!tables.iter().any(|n| n.contains("event")));
}
#[test]
fn exclusions_case_insensitive_and_invalid_config_rejected() {
    let mut c = Config::default();
    assert!(c.excludes("bitwarden"));
    assert!(!c.excludes("firefox"));
    c.input_mode = "guess".into();
    assert!(c.validate().is_err());
}
#[test]
fn mac_import_maps_codes_and_is_idempotent() {
    let d = tempfile::tempdir().unwrap();
    let src = d.path().join("mac.db");
    let dst = d.path().join("linux.db");
    let c = rusqlite::Connection::open(&src).unwrap();
    c.execute_batch("CREATE TABLE counts(hour INTEGER,keycode INTEGER,app TEXT,n INTEGER); INSERT INTO counts VALUES(100,0,'editor',5),(100,51,'editor',2);").unwrap();
    drop(c);
    let before = std::fs::read(&src).unwrap();
    assert_eq!(import_macos(&src, &dst).unwrap(), 7);
    let s = Store::read(&dst).unwrap();
    let data = s.snapshot(&Filter::default()).unwrap();
    assert!(data.keys.contains(&(30, 5)));
    assert_eq!(data.corrections, 2);
    assert!(import_macos(&src, &dst).is_err());
    assert_eq!(before, std::fs::read(src).unwrap());
}
#[test]
fn refuse_legacy_database_as_linux() {
    let d = tempfile::tempdir().unwrap();
    let p = d.path().join("old.db");
    let c = rusqlite::Connection::open(&p).unwrap();
    c.execute_batch("CREATE TABLE counts(hour INTEGER,keycode INTEGER,app TEXT,n INTEGER);")
        .unwrap();
    drop(c);
    assert!(Store::open(&p).is_err());
}
#[test]
fn jis_and_mac_mapping() {
    assert_eq!(keys::label_layout(26, true), "@");
    assert_eq!(keys::from_macos(0), Some(30));
    assert_eq!(keys::from_macos(51), Some(14));
    assert_eq!(keys::from_macos(999), None);
}

#[test]
fn gate_discards_transitions_and_inactive_sessions() {
    use keystats_linux::engine::stable_interval as gate;
    assert!(gate(true, true, "editor", "editor", false));
    for (before, after, old, new, change) in [
        (false, true, "editor", "editor", false),
        (true, false, "editor", "editor", false),
        (true, true, "editor", "vault", false),
        (true, true, "editor", "editor", true),
    ] {
        assert!(!gate(before, after, old, new, change));
    }
}
#[test]
fn resync_preserves_held_modifiers_without_counting_them() {
    let mut e = Engine::default();
    e.sync_down("keyboard", [29]);
    let r = press(&mut e, 44, 1.0, "new-app");
    assert!(r.correction);
    assert_eq!(r.combo.as_deref(), Some("Ctrl+Z"));
    assert!(r.weights.is_empty());
    e.event(29, 0, "keyboard", "new-app", 1.1, 3600);
    assert_eq!(press(&mut e, 44, 1.2, "new-app").combo, None);
}
