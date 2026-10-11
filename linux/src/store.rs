use crate::{engine::Record, keys};
use anyhow::Result;
use chrono::{DateTime, Datelike, Local, TimeZone};
use rusqlite::{params, Connection, OpenFlags};
use serde::Serialize;
use std::{collections::BTreeMap, path::Path, time::Duration};
#[derive(Default, Clone, Debug)]
pub struct Filter {
    pub since: i64,
    pub app: Option<String>,
    pub key: Option<u16>,
    pub device: Option<String>,
}
#[derive(Default, Serialize, Debug)]
pub struct Snapshot {
    pub total: i64,
    pub corrections: i64,
    pub active_ms: i64,
    pub speed_keys: i64,
    pub peak_kpm: i64,
    pub keys: Vec<(u16, i64)>,
    pub apps: Vec<(String, i64)>,
    pub devices: Vec<(String, i64)>,
    pub combos: Vec<(String, i64)>,
    pub weak: Vec<(u16, f64, i64)>,
    pub apptime: Vec<(String, i64)>,
    pub hours: Vec<i64>,
    pub weekdays: Vec<Vec<i64>>,
    pub days: Vec<(String, i64)>,
}
impl Snapshot {
    pub fn avg_kpm(&self) -> i64 {
        if self.active_ms > 0 {
            self.speed_keys * 60000 / self.active_ms
        } else {
            0
        }
    }
    pub fn correction_rate(&self) -> f64 {
        if self.total > 0 {
            self.corrections as f64 / self.total as f64 * 100.0
        } else {
            0.0
        }
    }
}
pub struct Store {
    pub conn: Connection,
}
const SCHEMA: &str = r#"
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY,value TEXT NOT NULL);
INSERT OR IGNORE INTO meta VALUES('schema','1');
CREATE TABLE IF NOT EXISTS counts(hour INTEGER NOT NULL,keycode INTEGER NOT NULL,app TEXT NOT NULL,device TEXT NOT NULL,n INTEGER NOT NULL,corrections INTEGER NOT NULL,PRIMARY KEY(hour,keycode,app,device)) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS combos(hour INTEGER NOT NULL,keycode INTEGER NOT NULL,combo TEXT NOT NULL,app TEXT NOT NULL,device TEXT NOT NULL,n INTEGER NOT NULL,PRIMARY KEY(hour,keycode,combo,app,device)) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS typing(hour INTEGER NOT NULL,app TEXT NOT NULL,device TEXT NOT NULL,active_ms INTEGER NOT NULL,keys INTEGER NOT NULL,peak_kpm INTEGER NOT NULL,PRIMARY KEY(hour,app,device)) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS mistype(hour INTEGER NOT NULL,keycode INTEGER NOT NULL,app TEXT NOT NULL,device TEXT NOT NULL,weight REAL NOT NULL,PRIMARY KEY(hour,keycode,app,device)) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS apptime(hour INTEGER NOT NULL,app TEXT NOT NULL,ms INTEGER NOT NULL,PRIMARY KEY(hour,app)) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS counts_app ON counts(app,hour);
"#;
impl Store {
    pub fn open(path: &Path) -> Result<Self> {
        if let Some(p) = path.parent() {
            std::fs::create_dir_all(p)?;
        }
        let conn = Connection::open(path)?;
        conn.busy_timeout(Duration::from_secs(2))?;
        // Refuse a Swift database, never reinterpret macOS keycodes as Linux codes.
        let legacy: i64 = conn.query_row(
            "SELECT count(*) FROM sqlite_master WHERE name='counts'",
            [],
            |r| r.get(0),
        )?;
        if legacy > 0 {
            let mut q = conn.prepare("PRAGMA table_info(counts)")?;
            let cols = q
                .query_map([], |r| r.get::<_, String>(1))?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            anyhow::ensure!(
                cols.contains(&"device".into()),
                "macOS database: use import-macos into a separate Linux database"
            );
        }
        conn.execute_batch(SCHEMA)?;
        let schema: String =
            conn.query_row("SELECT value FROM meta WHERE key='schema'", [], |r| {
                r.get(0)
            })?;
        anyhow::ensure!(schema == "1", "unsupported database schema {schema}");
        Ok(Self { conn })
    }
    pub fn read(path: &Path) -> Result<Self> {
        let conn = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
        conn.busy_timeout(Duration::from_millis(500))?;
        Ok(Self { conn })
    }
    pub fn flush(&mut self, records: &[Record], times: &[(i64, String, i64)]) -> Result<()> {
        let tx = self.conn.transaction()?;
        for r in records {
            tx.execute("INSERT INTO counts VALUES (?1,?2,?3,?4,1,?5) ON CONFLICT(hour,keycode,app,device) DO UPDATE SET n=n+1,corrections=corrections+excluded.corrections",params![r.hour,r.key,r.app,r.device,r.correction as i64])?;
            if let Some(c) = &r.combo {
                tx.execute("INSERT INTO combos VALUES (?1,?2,?3,?4,?5,1) ON CONFLICT(hour,keycode,combo,app,device) DO UPDATE SET n=n+1",params![r.hour,r.key,c,r.app,r.device])?;
            }
            if r.speed_keys > 0 {
                tx.execute("INSERT INTO typing VALUES (?1,?2,?3,?4,?5,?6) ON CONFLICT(hour,app,device) DO UPDATE SET active_ms=active_ms+excluded.active_ms,keys=keys+excluded.keys,peak_kpm=MAX(peak_kpm,excluded.peak_kpm)",params![r.hour,r.app,r.device,r.active_ms,r.speed_keys,r.peak_kpm])?;
            }
            for (key, weight) in &r.weights {
                tx.execute("INSERT INTO mistype VALUES (?1,?2,?3,?4,?5) ON CONFLICT(hour,keycode,app,device) DO UPDATE SET weight=weight+excluded.weight",params![r.hour,key,r.app,r.device,weight])?;
            }
        }
        for (hour, app, ms) in times {
            tx.execute("INSERT INTO apptime VALUES (?1,?2,?3) ON CONFLICT(hour,app) DO UPDATE SET ms=ms+excluded.ms",params![hour,app,ms])?;
        }
        tx.commit()?;
        Ok(())
    }
    pub fn snapshot(&self, f: &Filter) -> Result<Snapshot> {
        let mut s = Snapshot {
            hours: vec![0; 24],
            weekdays: vec![vec![0; 24]; 7],
            ..Default::default()
        };
        let clause="hour>=?1 AND (?2 IS NULL OR app=?2) AND (?3 IS NULL OR keycode=?3) AND (?4 IS NULL OR device=?4)";
        let bind = params![f.since, f.app, f.key, f.device];
        let mut q = self.conn.prepare(&format!(
            "SELECT hour,keycode,app,device,n,corrections FROM counts WHERE {clause}"
        ))?;
        let mut km = BTreeMap::new();
        let mut am = BTreeMap::new();
        let mut dm = BTreeMap::new();
        let mut days = BTreeMap::new();
        let mut rows = q.query(bind)?;
        while let Some(r) = rows.next()? {
            let h: i64 = r.get(0)?;
            let k: u16 = r.get(1)?;
            let app: String = r.get(2)?;
            let dev: String = r.get(3)?;
            let n: i64 = r.get(4)?;
            s.total += n;
            s.corrections += r.get::<_, i64>(5)?;
            *km.entry(k).or_insert(0) += n;
            *am.entry(app).or_insert(0) += n;
            *dm.entry(dev).or_insert(0) += n;
            if let Some(dt) = DateTime::from_timestamp(h * 3600, 0) {
                let l = dt.with_timezone(&Local);
                use chrono::Timelike;
                let hour = l.hour() as usize;
                s.hours[hour] += n;
                s.weekdays[l.weekday().num_days_from_monday() as usize][hour] += n;
                *days.entry(l.format("%Y-%m-%d").to_string()).or_insert(0) += n;
            }
        }
        fn ranked<K: Ord>(m: BTreeMap<K, i64>) -> Vec<(K, i64)> {
            let mut v: Vec<_> = m.into_iter().collect();
            v.sort_by(|a, b| b.1.cmp(&a.1));
            v
        }
        s.keys = ranked(km);
        s.apps = ranked(am);
        s.devices = ranked(dm);
        s.days = days.into_iter().collect();
        let mut q = self.conn.prepare(&format!(
            "SELECT combo,SUM(n) FROM combos WHERE {clause} GROUP BY combo ORDER BY SUM(n) DESC"
        ))?;
        s.combos = q
            .query_map(bind, |r| Ok((r.get(0)?, r.get(1)?)))?
            .collect::<rusqlite::Result<_>>()?;
        let mut q = self.conn.prepare(&format!(
            "SELECT keycode,SUM(weight) FROM mistype WHERE {clause} GROUP BY keycode"
        ))?;
        for entry in q.query_map(bind, |r| Ok((r.get::<_, u16>(0)?, r.get::<_, f64>(1)?)))? {
            let (k, w) = entry?;
            let count = s
                .keys
                .iter()
                .find(|(key, _)| *key == k)
                .map_or(0, |(_, n)| *n);
            if count > 0 {
                s.weak.push((k, w, count));
            }
        }
        s.weak
            .sort_by(|a, b| (b.1 / b.2 as f64).total_cmp(&(a.1 / a.2 as f64)));
        if f.key.is_none() {
            (s.active_ms,s.speed_keys,s.peak_kpm)=self.conn.query_row("SELECT COALESCE(SUM(active_ms),0),COALESCE(SUM(keys),0),COALESCE(MAX(peak_kpm),0) FROM typing WHERE hour>=?1 AND (?2 IS NULL OR app=?2) AND (?3 IS NULL OR device=?3)",params![f.since,f.app,f.device],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?)))?;
        }
        if f.key.is_none() && f.device.is_none() {
            let mut q=self.conn.prepare("SELECT app,SUM(ms) FROM apptime WHERE hour>=?1 AND (?2 IS NULL OR app=?2) GROUP BY app ORDER BY SUM(ms) DESC")?;
            s.apptime = q
                .query_map(params![f.since, f.app], |r| Ok((r.get(0)?, r.get(1)?)))?
                .collect::<rusqlite::Result<_>>()?;
        }
        Ok(s)
    }
    pub fn prune(&mut self, days: u32) -> Result<usize> {
        anyhow::ensure!(days > 0, "days must be positive");
        let cutoff = chrono::Utc::now().timestamp() / 3600 - i64::from(days) * 24;
        let tx = self.conn.transaction()?;
        let mut removed = 0;
        for t in ["counts", "combos", "typing", "mistype", "apptime"] {
            removed += tx.execute(&format!("DELETE FROM {t} WHERE hour<?1"), [cutoff])?;
        }
        tx.commit()?;
        Ok(removed)
    }
    pub fn export_csv(&self, f: &Filter) -> Result<String> {
        let s = self.snapshot(f)?;
        let mut out = "keycode,key,count\n".to_owned();
        for (k, n) in s.keys {
            out.push_str(&format!(
                "{k},\"{}\",{n}\n",
                keys::label(k).replace('"', "\"\"")
            ))
        }
        Ok(out)
    }
}
pub fn since_period(period: &str) -> i64 {
    let now = Local::now();
    let date = if period == "week" {
        now.date_naive() - chrono::Duration::days(i64::from(now.weekday().num_days_from_monday()))
    } else {
        now.date_naive()
    };
    if period == "all" {
        0
    } else {
        Local
            .from_local_datetime(&date.and_hms_opt(0, 0, 0).unwrap())
            .earliest()
            .map_or(0, |d| d.timestamp() / 3600)
    }
}
pub fn import_macos(source: &Path, target: &Path) -> Result<i64> {
    anyhow::ensure!(source.is_file(), "source database does not exist");
    if target.exists() {
        anyhow::ensure!(
            source.canonicalize()? != target.canonicalize()?,
            "source and target must differ"
        );
    }
    let source = source.canonicalize()?;
    let mut dst = Store::open(target)?;
    let src = Connection::open_with_flags(&source, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
    src.busy_timeout(Duration::from_secs(2))?;
    src.execute_batch("BEGIN")?;
    let names = src
        .prepare("PRAGMA table_info(counts)")?
        .query_map([], |r| r.get::<_, String>(1))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    anyhow::ensure!(
        names.contains(&"keycode".into()) && !names.contains(&"device".into()),
        "not a macOS KeyStats database"
    );
    let marker = format!("import:{}", source.display());
    let exists: i64 =
        dst.conn
            .query_row("SELECT count(*) FROM meta WHERE key=?1", [&marker], |r| {
                r.get(0)
            })?;
    anyhow::ensure!(exists == 0, "this source has already been imported");
    let has = |t: &str| -> Result<bool> {
        Ok(src.query_row(
            "SELECT count(*) FROM sqlite_master WHERE type='table' AND name=?1",
            [t],
            |r| r.get::<_, i64>(0),
        )? > 0)
    };
    let tx = dst.conn.transaction()?;
    let mut total = 0;
    let mut q = src.prepare("SELECT hour,keycode,app,n FROM counts")?;
    for row in q.query_map([], |r| {
        Ok((
            r.get::<_, i64>(0)?,
            r.get::<_, u16>(1)?,
            r.get::<_, String>(2)?,
            r.get::<_, i64>(3)?,
        ))
    })? {
        let (h, k, a, n) = row?;
        let k = keys::from_macos(k).unwrap_or(1000 + k);
        tx.execute("INSERT INTO counts VALUES (?1,?2,?3,'macOS import',?4,?5) ON CONFLICT(hour,keycode,app,device) DO UPDATE SET n=n+excluded.n,corrections=corrections+excluded.corrections",params![h,k,a,n,if matches!(k,14|111){n}else{0}])?;
        total += n;
    }
    if has("combos")? {
        let mut q = src.prepare("SELECT hour,combo,app,n FROM combos")?;
        for row in q.query_map([], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, i64>(3)?,
            ))
        })? {
            let (h, c, a, n) = row?;
            tx.execute("INSERT INTO combos VALUES (?1,0,?2,?3,'macOS import',?4) ON CONFLICT(hour,keycode,combo,app,device) DO UPDATE SET n=n+excluded.n",params![h,c,a,n])?;
        }
    }
    if has("typing_app")? {
        let mut q = src.prepare("SELECT hour,app,active_ms,keys,peak_kpm FROM typing_app")?;
        for row in q.query_map([], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, i64>(2)?,
                r.get::<_, i64>(3)?,
                r.get::<_, i64>(4)?,
            ))
        })? {
            let (h, a, m, k, p) = row?;
            tx.execute("INSERT INTO typing VALUES (?1,?2,'macOS import',?3,?4,?5) ON CONFLICT(hour,app,device) DO UPDATE SET active_ms=active_ms+excluded.active_ms,keys=keys+excluded.keys,peak_kpm=MAX(peak_kpm,excluded.peak_kpm)",params![h,a,m,k,p])?;
        }
    }
    if has("mistype")? {
        let mut q = src.prepare("SELECT hour,keycode,weight FROM mistype")?;
        for row in q.query_map([], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, u16>(1)?,
                r.get::<_, f64>(2)?,
            ))
        })? {
            let (h, k, w) = row?;
            let k = keys::from_macos(k).unwrap_or(1000 + k);
            tx.execute("INSERT INTO mistype VALUES (?1,?2,'','macOS import',?3) ON CONFLICT(hour,keycode,app,device) DO UPDATE SET weight=weight+excluded.weight",params![h,k,w])?;
        }
    }
    if has("apptime")? {
        let mut q = src.prepare("SELECT hour,app,seconds FROM apptime")?;
        for row in q.query_map([], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, i64>(2)?,
            ))
        })? {
            let (h, a, seconds) = row?;
            tx.execute("INSERT INTO apptime VALUES (?1,?2,?3) ON CONFLICT(hour,app) DO UPDATE SET ms=ms+excluded.ms",params![h,a,seconds*1000])?;
        }
    }
    tx.execute("INSERT INTO meta VALUES (?1,'imported')", [marker])?;
    tx.commit()?;
    Ok(total)
}
