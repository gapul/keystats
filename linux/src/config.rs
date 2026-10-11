use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::{
    env, fs,
    path::{Path, PathBuf},
};
fn xdg(var: &str, fallback: &str) -> PathBuf {
    env::var_os(var)
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .unwrap_or_else(|| PathBuf::from(env::var_os("HOME").unwrap_or_default()).join(fallback))
        .join("keystats")
}
pub fn data_dir() -> PathBuf {
    xdg("XDG_DATA_HOME", ".local/share")
}
pub fn config_path() -> PathBuf {
    xdg("XDG_CONFIG_HOME", ".config").join("linux.json")
}
pub fn db_path() -> PathBuf {
    data_dir().join("linux.db")
}
pub fn runtime_dir() -> PathBuf {
    env::var_os("XDG_RUNTIME_DIR")
        .map(|p| PathBuf::from(p).join("keystats"))
        .unwrap_or_else(|| xdg("XDG_STATE_HOME", ".local/state"))
}
pub fn paused() -> bool {
    runtime_dir().join("paused").exists()
}
pub fn pause(value: bool) -> Result<()> {
    let dir = runtime_dir();
    fs::create_dir_all(&dir)?;
    let path = dir.join("paused");
    if value {
        fs::write(path, b"")?
    } else if path.exists() {
        fs::remove_file(path)?
    }
    Ok(())
}
#[derive(Clone, Serialize, Deserialize, Debug, PartialEq)]
#[serde(default)]
pub struct Config {
    pub language: String,
    pub layout: String,
    pub excluded_apps: Vec<String>,
    pub excluded_devices: Vec<String>,
    pub input_mode: String,
}
impl Default for Config {
    fn default() -> Self {
        Self {
            language: "ja".into(),
            layout: "ansi".into(),
            excluded_apps: vec![
                "org.keepassxc.KeePassXC".into(),
                "Bitwarden".into(),
                "1Password".into(),
            ],
            excluded_devices: vec!["Espanso".into()],
            input_mode: "auto".into(),
        }
    }
}
impl Config {
    pub fn load() -> Result<Self> {
        let p = config_path();
        if !p.exists() {
            return Ok(Self::default());
        }
        let c: Self = serde_json::from_slice(&fs::read(p)?).context("invalid linux.json")?;
        c.validate()?;
        Ok(c)
    }
    pub fn validate(&self) -> Result<()> {
        anyhow::ensure!(
            ["ja", "en"].contains(&self.language.as_str()),
            "language must be ja or en"
        );
        anyhow::ensure!(
            ["ansi", "jis"].contains(&self.layout.as_str()),
            "layout must be ansi or jis"
        );
        anyhow::ensure!(
            ["auto", "physical", "xremap"].contains(&self.input_mode.as_str()),
            "input_mode must be auto, physical or xremap"
        );
        Ok(())
    }
    pub fn save(&self) -> Result<()> {
        self.validate()?;
        atomic_json(&config_path(), self)
    }
    pub fn excludes(&self, app: &str) -> bool {
        self.excluded_apps
            .iter()
            .any(|a| a.eq_ignore_ascii_case(app))
    }
}
pub fn atomic_json(path: &Path, value: &impl Serialize) -> Result<()> {
    let parent = path.parent().context("missing parent")?;
    fs::create_dir_all(parent)?;
    let tmp = path.with_extension(format!("tmp-{}", std::process::id()));
    fs::write(&tmp, serde_json::to_vec_pretty(value)?)?;
    fs::rename(tmp, path)?;
    Ok(())
}
