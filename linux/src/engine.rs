use crate::keys;
use std::collections::{HashMap, HashSet, VecDeque};
#[derive(Debug, Clone)]
pub struct Record {
    pub hour: i64,
    pub key: u16,
    pub app: String,
    pub device: String,
    pub combo: Option<String>,
    pub correction: bool,
    pub active_ms: i64,
    pub speed_keys: i64,
    pub peak_kpm: i64,
    pub weights: Vec<(u16, f64)>,
}
#[derive(Default)]
pub struct Engine {
    down: HashMap<String, HashSet<u16>>,
    context: Option<(String, String, i64)>,
    last: Option<f64>,
    recent: VecDeque<f64>,
    typed: VecDeque<(u16, f64)>,
}
/// Transition intervals are discarded, including switch-away-and-back notifications.
pub fn stable_interval(
    before: bool,
    after: bool,
    old_app: &str,
    new_app: &str,
    transition: bool,
) -> bool {
    before && after && old_app == new_app && !transition
}
impl Engine {
    /// Seed current physical state after a gate/hotplug without recording it as input.
    pub fn sync_down(&mut self, device: &str, keys: impl IntoIterator<Item = u16>) {
        self.down.insert(device.into(), keys.into_iter().collect());
    }
    pub fn reset(&mut self) {
        *self = Self::default()
    }
    pub fn release_device(&mut self, id: &str) {
        self.down.remove(id);
        self.context = None;
        self.last = None;
        self.recent.clear();
        self.typed.clear()
    }
    /// value 0=release, 1=physical press, 2=autorepeat. No key sequence is persisted.
    pub fn event(
        &mut self,
        key: u16,
        value: i32,
        device: &str,
        app: &str,
        monotonic: f64,
        epoch: i64,
    ) -> Option<Record> {
        let down = self.down.entry(device.into()).or_default();
        if value == 0 {
            down.remove(&key);
            return None;
        }
        if value != 1 || key >= 256 || !down.insert(key) {
            return None;
        }
        let all: HashSet<u16> = self.down.values().flat_map(|s| s.iter().copied()).collect();
        let hour = epoch.div_euclid(3600);
        let context = (app.into(), device.into(), hour);
        if self.context.as_ref() != Some(&context) {
            self.last = None;
            self.recent.clear();
            self.typed.clear();
            self.context = Some(context)
        }
        let ctrl = all.contains(&29) || all.contains(&97);
        let correction = keys::correction(key, ctrl);
        let mut r = Record {
            hour,
            key,
            app: app.into(),
            device: device.into(),
            combo: keys::combo(key, &all),
            correction,
            active_ms: 0,
            speed_keys: 0,
            peak_kpm: 0,
            weights: vec![],
        };
        if correction {
            for (i, (k, t)) in self.typed.iter().rev().take(4).enumerate() {
                if monotonic - t > 3.0 {
                    break;
                }
                r.weights.push((*k, 0.5f64.powi(i as i32)))
            }
            if ctrl && key == 44 {
                self.typed.clear()
            } else {
                self.typed.pop_back();
            }
        } else if keys::typing(key)
            && !ctrl
            && !all.contains(&56)
            && !all.contains(&100)
            && !all.contains(&125)
            && !all.contains(&126)
        {
            self.typed.push_back((key, monotonic));
            while self.typed.len() > 4 {
                self.typed.pop_front();
            }
        }
        if !correction && !keys::modifier(key) {
            if let Some(last) = self.last {
                let gap = monotonic - last;
                if gap > 0.0 && gap < 2.0 {
                    r.active_ms = (gap * 1000.0).round() as i64;
                    r.speed_keys = 1;
                    self.recent.push_back(monotonic);
                    while self.recent.front().is_some_and(|t| monotonic - t > 5.0) {
                        self.recent.pop_front();
                    }
                    if self.recent.len() >= 5 {
                        let span = monotonic - self.recent[0];
                        if span >= 2.0 {
                            r.peak_kpm = (self.recent.len() as f64 / span * 60.0) as i64
                        }
                    }
                } else {
                    self.recent.clear();
                    self.recent.push_back(monotonic)
                }
            } else {
                self.recent.push_back(monotonic)
            }
            self.last = Some(monotonic);
        }
        Some(r)
    }
}
