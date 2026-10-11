use anyhow::Result;
use clap::Parser;
use keystats_linux::{
    config, keys,
    store::{since_period, Filter, Store},
};
#[derive(Parser)]
#[command(
    version,
    about = "Native Linux keyboard statistics — aggregate counts only"
)]
struct Args {
    #[arg(long)]
    db: Option<std::path::PathBuf>,
    #[arg(long,default_value="all",value_parser=["all","today","week"])]
    period: String,
    #[arg(long)]
    app: Option<String>,
    #[arg(long)]
    key: Option<u16>,
    #[arg(long)]
    device: Option<String>,
    #[arg(default_value = "gui")]
    command: String,
    argument: Option<String>,
}
fn main() -> Result<()> {
    unsafe {
        libc::umask(0o077);
    }
    let args = Args::parse();
    let path = args.db.unwrap_or_else(config::db_path);
    let filter = Filter {
        since: since_period(&args.period),
        app: args.app,
        key: args.key,
        device: args.device,
    };
    match args.command.as_str() {
        "daemon" => {
            #[cfg(target_os = "linux")]
            return keystats_linux::daemon::run(&path);
            #[cfg(not(target_os = "linux"))]
            anyhow::bail!("Linux required");
        }
        "gui" => {
            #[cfg(all(target_os = "linux", feature = "gui"))]
            return keystats_linux::gui::run(path);
            #[cfg(not(all(target_os = "linux", feature = "gui")))]
            anyhow::bail!("build with --features gui on Linux");
        }
        "where" => {
            println!("{}", path.display());
            return Ok(());
        }
        "pause" => {
            config::pause(true)?;
            return Ok(());
        }
        "resume" => {
            config::pause(false)?;
            return Ok(());
        }
        "status" => {
            println!(
                "{}",
                std::fs::read_to_string(config::runtime_dir().join("status.json"))
                    .unwrap_or_else(|_| "{\"running\":false}".into())
            );
            return Ok(());
        }
        "prune" => {
            let days = args.argument.as_deref().unwrap_or("0").parse()?;
            println!("{}", Store::open(&path)?.prune(days)?);
            return Ok(());
        }
        "import-macos" => {
            let source = args
                .argument
                .as_deref()
                .ok_or_else(|| anyhow::anyhow!("provide the macOS database path"))?;
            println!(
                "{}",
                keystats_linux::store::import_macos(std::path::Path::new(source), &path)?
            );
            return Ok(());
        }
        _ => {}
    }
    let store = Store::read(&path)?;
    let s = store.snapshot(&filter)?;
    let limit = args
        .argument
        .as_deref()
        .and_then(|s| s.parse::<usize>().ok())
        .unwrap_or(20);
    match args.command.as_str(){
        "today"=>println!("{}",store.snapshot(&Filter{since:since_period("today"),..filter})?.total),
        "top"=>for(k,n)in s.keys.iter().take(limit){println!("{:12} {}",keys::label(*k),n)},
        "apps"=>for(a,n)in &s.apps{println!("{n}\t{a}")},
        "keyboards"=>for(a,n)in &s.devices{println!("{n}\t{a}")},
        "combos"=>for(a,n)in s.combos.iter().take(limit){println!("{n}\t{a}")},
        "weak"=>for(k,w,n)in s.weak.iter().take(limit){println!("{}\t{:.1}%\t{}",keys::label(*k),w/(*n as f64)*100.0,n)},
        "speed"=>println!("average={} KPM peak={} KPM active={}s corrections={:.1}%",s.avg_kpm(),s.peak_kpm,s.active_ms/1000,s.correction_rate()),
        "export"=>if args.argument.as_deref()==Some("csv"){print!("{}",store.export_csv(&filter)?)}else{println!("{}",serde_json::to_string_pretty(&s)?)},
        _=>anyhow::bail!("unknown command; use gui, daemon, status, today, top, apps, combos, speed, weak, keyboards, export, where, pause, resume, import-macos, prune"),
    }
    Ok(())
}
