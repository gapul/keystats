use crate::{
    config::{self, Config},
    keys,
    store::{since_period, Filter, Snapshot, Store},
};
use anyhow::Result;
use gtk4::{self as gtk, glib, prelude::*};
use std::{cell::RefCell, path::PathBuf, rc::Rc};
#[derive(Clone)]
struct Ui {
    path: PathBuf,
    filter: Rc<RefCell<Filter>>,
    body: gtk::Box,
    status: gtk::Label,
    summary: gtk::Label,
    ja: bool,
    layout: Rc<RefCell<String>>,
    period: Rc<RefCell<String>>,
    last_render: Rc<RefCell<String>>,
}
fn text(ja: bool, j: &str, e: &str) -> String {
    if ja { j } else { e }.into()
}
fn label(s: &str, class: &str) -> gtk::Label {
    let l = gtk::Label::new(Some(s));
    l.set_xalign(0.0);
    l.add_css_class(class);
    l
}
fn column() -> gtk::Box {
    gtk::Box::new(gtk::Orientation::Vertical, 12)
}
fn section(title: &str) -> gtk::Box {
    let b = column();
    b.add_css_class("card");
    b.append(&label(title, "heading"));
    b
}
fn clear(b: &gtk::Box) {
    while let Some(child) = b.first_child() {
        b.remove(&child)
    }
}
fn error_dialog(parent: &gtk::ApplicationWindow, msg: &str) {
    let d = gtk::MessageDialog::builder()
        .transient_for(parent)
        .modal(true)
        .message_type(gtk::MessageType::Error)
        .buttons(gtk::ButtonsType::Close)
        .text(msg)
        .build();
    d.connect_response(|d, _| d.close());
    d.present();
}
impl Ui {
    fn refresh(&self) {
        self.filter.borrow_mut().since = since_period(&self.period.borrow());
        let status = std::fs::read_to_string(config::runtime_dir().join("status.json"))
            .ok()
            .and_then(|s| serde_json::from_str::<serde_json::Value>(&s).ok());
        let live = status.as_ref().is_some_and(|s| {
            s["running"].as_bool() == Some(true)
                && chrono::Utc::now().timestamp() - s["updated"].as_i64().unwrap_or(0) < 8
        });
        let reason = status
            .as_ref()
            .and_then(|s| s["reason"].as_str())
            .unwrap_or("");
        let state = if config::paused() {
            text(self.ja, "一時停止中", "Paused")
        } else if live && reason.is_empty() {
            text(
                self.ja,
                "● 記録中 · ローカル保存",
                "● Recording · stored locally",
            )
        } else if live {
            format!("{}: {}", text(self.ja, "待機中", "Waiting"), reason)
        } else {
            text(self.ja, "収集デーモンは停止中", "Collector is stopped")
        };
        self.status.set_text(&state);
        let f = self.filter.borrow().clone();
        let selected = [f.app.clone(), f.key.map(keys::label), f.device.clone()]
            .into_iter()
            .flatten()
            .collect::<Vec<_>>()
            .join(" / ");
        self.summary.set_text(if selected.is_empty() {
            if self.ja {
                "すべてのアプリ・キーボード"
            } else {
                "All applications and keyboards"
            }
        } else {
            &selected
        });
        let data = if self.path.exists() {
            Store::read(&self.path).and_then(|s| s.snapshot(&f))
        } else {
            Ok(Snapshot {
                hours: vec![0; 24],
                weekdays: vec![vec![0; 24]; 7],
                ..Default::default()
            })
        };
        let signature = format!("{:?}|{:?}|{}", data, f, self.layout.borrow());
        if *self.last_render.borrow() == signature {
            return;
        }
        *self.last_render.borrow_mut() = signature;
        clear(&self.body);
        match data {
            Ok(s) => self.render(s),
            Err(e) => self.body.append(&label(
                &format!(
                    "{}: {e}",
                    text(self.ja, "読み込めません", "Could not load statistics")
                ),
                "error",
            )),
        }
    }
    fn render(&self, s: Snapshot) {
        let cards = gtk::Box::new(gtk::Orientation::Horizontal, 12);
        cards.set_homogeneous(true);
        let metrics = [
            (text(self.ja, "総打鍵", "Keystrokes"), s.total.to_string()),
            (
                text(self.ja, "平均 / ピーク KPM", "Average / peak KPM"),
                format!("{} / {}", s.avg_kpm(), s.peak_kpm),
            ),
            (
                text(self.ja, "修正率", "Correction rate"),
                format!("{:.1}%", s.correction_rate()),
            ),
            (
                text(self.ja, "実打鍵時間", "Active typing"),
                format!("{}m {}s", s.active_ms / 60000, s.active_ms / 1000 % 60),
            ),
        ];
        for (title, value) in metrics {
            let b = section(&title);
            b.append(&label(&value, "stat"));
            cards.append(&b)
        }
        self.body.append(&cards);
        if s.total == 0 {
            let empty = label(
                &text(
                    self.ja,
                    "まだ記録がありません。収集中は数秒ごとに更新されます。",
                    "No data yet. Statistics refresh every few seconds while recording.",
                ),
                "dim-label",
            );
            empty.set_wrap(true);
            self.body.append(&empty)
        }
        let heat = section(&text(
            self.ja,
            "キーボード · キーを押して絞り込み",
            "Keyboard · click a key to filter",
        ));
        let max = s.keys.iter().map(|(_, n)| *n).max().unwrap_or(1).max(1) as f64;
        let mut rows = keys::ROWS.to_vec();
        if self.layout.borrow().as_str() == "jis" {
            rows.push(&[89, 90, 92, 94, 124]);
        }
        for keys_row in rows {
            let row = gtk::Box::new(gtk::Orientation::Horizontal, 4);
            row.set_homogeneous(true);
            for k in keys_row {
                let k = *k;
                let n = s
                    .keys
                    .iter()
                    .find(|(key, _)| *key == k)
                    .map_or(0, |(_, n)| *n);
                let name = keys::label_layout(k, self.layout.borrow().as_str() == "jis");
                let b = gtk::Button::with_label(&name);
                b.add_css_class("keycap");
                b.add_css_class(&format!(
                    "heat{}",
                    if n == 0 {
                        0
                    } else {
                        1 + (n as f64 / max * 4.0).round() as u32
                    }
                ));
                b.set_tooltip_text(Some(&format!("{name}: {n}")));
                let ui = self.clone();
                b.connect_clicked(move |_| {
                    ui.filter.borrow_mut().key = Some(k);
                    ui.refresh()
                });
                row.append(&b);
            }
            heat.append(&row);
        }
        self.body.append(&heat);
        let chart = section(&text(self.ja, "時間帯別の打鍵", "Keystrokes by hour"));
        chart.append(&bars(
            s.hours
                .iter()
                .enumerate()
                .map(|(h, n)| (format!("{h}"), *n))
                .collect(),
            170,
        ));
        self.body.append(&chart);
        let trends = section(&text(
            self.ja,
            "日別トレンド · 直近14日",
            "Daily trend · last 14 days",
        ));
        let today = chrono::Local::now().date_naive();
        let days = (0..14)
            .rev()
            .map(|i| {
                let d = today - chrono::Duration::days(i);
                let key = d.format("%Y-%m-%d").to_string();
                (
                    d.format("%m/%d").to_string(),
                    s.days
                        .iter()
                        .find(|(date, _)| date == &key)
                        .map_or(0, |(_, n)| *n),
                )
            })
            .collect();
        trends.append(&bars(days, 155));
        self.body.append(&trends);
        let week = section(&text(self.ja, "曜日 × 時間帯", "Weekday × hour"));
        week.append(&week_heat(s.weekdays.clone(), self.ja));
        self.body.append(&week);
        let pair = gtk::Box::new(gtk::Orientation::Horizontal, 12);
        pair.set_homogeneous(true);
        let apps = section(&text(
            self.ja,
            "アプリ別 · クリックで詳細",
            "Applications · click for details",
        ));
        for (name, n) in s.apps.iter().take(15) {
            let b = gtk::Button::with_label(&format!("{name}    {n}"));
            b.add_css_class("flat");
            b.set_halign(gtk::Align::Fill);
            let ui = self.clone();
            let name = name.clone();
            b.connect_clicked(move |_| {
                ui.filter.borrow_mut().app = Some(name.clone());
                ui.refresh()
            });
            apps.append(&b)
        }
        let devices = section(&text(self.ja, "キーボード別", "Keyboards"));
        for (name, n) in s.devices.iter().take(15) {
            let b = gtk::Button::with_label(&format!("{name}    {n}"));
            b.add_css_class("flat");
            b.set_tooltip_text(Some(name));
            let ui = self.clone();
            let name = name.clone();
            b.connect_clicked(move |_| {
                ui.filter.borrow_mut().device = Some(name.clone());
                ui.refresh()
            });
            devices.append(&b)
        }
        pair.append(&apps);
        pair.append(&devices);
        self.body.append(&pair);
        let pair = gtk::Box::new(gtk::Orientation::Horizontal, 12);
        pair.set_homogeneous(true);
        let top = section(&text(self.ja, "よく使うキー", "Top keys"));
        for (k, n) in s.keys.iter().take(12) {
            top.append(&label(&format!("{}    {n}", keys::label(*k)), "body"))
        }
        let combos = section(&text(self.ja, "ショートカット", "Shortcuts"));
        for (c, n) in s.combos.iter().take(12) {
            combos.append(&label(&format!("{c}    {n}"), "body"))
        }
        pair.append(&top);
        pair.append(&combos);
        self.body.append(&pair);
        let pair = gtk::Box::new(gtk::Orientation::Horizontal, 12);
        pair.set_homogeneous(true);
        let weak = section(&text(
            self.ja,
            "修正直前のキー · 誤入力の推定",
            "Keys preceding corrections · estimate",
        ));
        for (k, w, n) in s.weak.iter().take(12) {
            weak.append(&label(
                &format!(
                    "{}    {:.1}%   ({n})",
                    keys::label(*k),
                    w / (*n as f64) * 100.0
                ),
                "body",
            ))
        }
        let times = section(&text(
            self.ja,
            "アプリ稼働時間 · 入力後60秒まで",
            "Application time · within 60s of typing",
        ));
        for (a, ms) in s.apptime.iter().take(12) {
            times.append(&label(&format!("{a}    {}m", ms / 60000), "body"))
        }
        pair.append(&weak);
        pair.append(&times);
        self.body.append(&pair);
    }
}
fn bars(data: Vec<(String, i64)>, height: i32) -> gtk::DrawingArea {
    let area = gtk::DrawingArea::new();
    area.set_content_height(height);
    area.set_hexpand(true);
    area.set_draw_func(move |_, cr, w, h| {
        let max = data.iter().map(|(_, n)| *n).max().unwrap_or(1).max(1) as f64;
        let step = w as f64 / data.len().max(1) as f64;
        cr.set_font_size(10.0);
        for (i, (name, n)) in data.iter().enumerate() {
            let x = i as f64 * step;
            let bar = (*n as f64 / max) * (h - 38) as f64;
            cr.set_source_rgb(0.47, 0.59, 0.84);
            cr.rectangle(
                x + 3.0,
                h as f64 - 24.0 - bar,
                (step - 6.0).max(1.0),
                bar.max(1.0),
            );
            let _ = cr.fill();
            cr.set_source_rgb(0.53, 0.55, 0.62);
            cr.move_to(x + 3.0, h as f64 - 7.0);
            let _ = cr.show_text(name);
        }
    });
    area
}
fn week_heat(data: Vec<Vec<i64>>, ja: bool) -> gtk::DrawingArea {
    let a = gtk::DrawingArea::new();
    a.set_content_height(165);
    a.set_hexpand(true);
    a.set_draw_func(move |_, cr, w, _| {
        let max = data.iter().flatten().copied().max().unwrap_or(1).max(1) as f64;
        let step = (w - 35) as f64 / 24.0;
        let names = if ja {
            ["月", "火", "水", "木", "金", "土", "日"]
        } else {
            ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]
        };
        cr.set_font_size(10.0);
        for (d, row) in data.iter().enumerate() {
            cr.set_source_rgb(0.53, 0.55, 0.62);
            cr.move_to(0.0, 19.0 + d as f64 * 20.0);
            let _ = cr.show_text(names[d]);
            for (h, n) in row.iter().enumerate() {
                let v = *n as f64 / max;
                cr.set_source_rgba(0.47, 0.59, 0.84, 0.10 + 0.9 * v);
                cr.rectangle(
                    34.0 + h as f64 * step,
                    6.0 + d as f64 * 20.0,
                    (step - 3.0).max(1.0),
                    16.0,
                );
                let _ = cr.fill();
            }
        }
    });
    a
}
fn settings(parent: &gtk::ApplicationWindow, ui: Ui) {
    let c = Config::load().unwrap_or_default();
    let w = gtk::Window::builder()
        .title(text(ui.ja, "設定", "Settings"))
        .transient_for(parent)
        .modal(true)
        .default_width(490)
        .build();
    let body = column();
    body.set_margin_top(24);
    body.set_margin_bottom(24);
    body.set_margin_start(24);
    body.set_margin_end(24);
    body.append(&label(
        &text(ui.ja, "言語（次回起動時）", "Language (next launch)"),
        "heading",
    ));
    let lang = gtk::DropDown::from_strings(&["日本語", "English"]);
    lang.set_selected(if c.language == "en" { 1 } else { 0 });
    body.append(&lang);
    body.append(&label(
        &text(ui.ja, "キーボード配列", "Keyboard layout"),
        "heading",
    ));
    let layout = gtk::DropDown::from_strings(&["ANSI", "JIS"]);
    layout.set_selected(if c.layout == "jis" { 1 } else { 0 });
    body.append(&layout);
    body.append(&label(&text(ui.ja, "入力元", "Input source"), "heading"));
    let mode =
        gtk::DropDown::from_strings(&["Auto (xremap / physical)", "Physical keyboards", "xremap"]);
    mode.set_selected(match c.input_mode.as_str() {
        "physical" => 1,
        "xremap" => 2,
        _ => 0,
    });
    body.append(&mode);
    body.append(&label(
        &text(
            ui.ja,
            "除外するアプリID（1行に1つ）",
            "Excluded application IDs (one per line)",
        ),
        "heading",
    ));
    let exclude = gtk::TextView::new();
    exclude.set_monospace(true);
    exclude.set_height_request(110);
    exclude.buffer().set_text(&c.excluded_apps.join("\n"));
    body.append(&exclude);
    let privacy=label(&text(ui.ja,"入力本文は保存せず、時間単位の集計だけを保存します。Linuxではパスワード欄を自動判別できません。必要なときは収集を一時停止してください。","Only hourly aggregates are stored, never typed text. Linux cannot reliably identify password fields. Pause collection when needed."),"dim-label");
    privacy.set_wrap(true);
    body.append(&privacy);
    let save = gtk::Button::with_label(&text(ui.ja, "保存", "Save"));
    save.add_css_class("suggested-action");
    let parent = parent.clone();
    let weak = w.downgrade();
    save.connect_clicked(move |_| {
        let mut c = Config::load().unwrap_or_default();
        c.language = if lang.selected() == 1 { "en" } else { "ja" }.into();
        c.layout = if layout.selected() == 1 {
            "jis"
        } else {
            "ansi"
        }
        .into();
        c.input_mode = match mode.selected() {
            1 => "physical",
            2 => "xremap",
            _ => "auto",
        }
        .into();
        let b = exclude.buffer();
        c.excluded_apps = b
            .text(&b.start_iter(), &b.end_iter(), false)
            .lines()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_owned)
            .collect();
        match c.save() {
            Ok(()) => {
                *ui.layout.borrow_mut() = c.layout;
                ui.refresh();
                if let Some(w) = weak.upgrade() {
                    w.close()
                }
            }
            Err(e) => error_dialog(&parent, &e.to_string()),
        }
    });
    body.append(&save);
    w.set_child(Some(&body));
    w.present();
}
pub fn run(path: PathBuf) -> Result<()> {
    let app = gtk::Application::builder()
        .application_id("net.gapul.KeyStats")
        .build();
    app.connect_activate(move|app|{
        if let Some(w)=app.active_window(){w.present();return}
        let config=Config::load().unwrap_or_default();let ja=config.language!="en";
        let window=gtk::ApplicationWindow::builder().application(app).title("KeyStats").default_width(1060).default_height(820).build();
        let css=gtk::CssProvider::new();css.load_from_data(".dashboard { padding: 22px; } .card { background: alpha(@theme_fg_color,0.035); border: 1px solid alpha(@theme_fg_color,0.10); border-radius: 14px; padding: 18px; } .heading { font-weight: 600; } .stat { font-size: 27px; font-weight: 700; margin-top: 8px; } .keycap { padding: 10px 2px; min-width: 30px; border-radius: 7px; font-size: 11px; } .heat0 { background: alpha(@theme_fg_color,0.035); } .heat1 { background: alpha(#7897d6,0.18); } .heat2 { background: alpha(#7897d6,0.32); } .heat3 { background: alpha(#7897d6,0.48); } .heat4 { background: alpha(#7897d6,0.65); } .heat5 { background: #7897d6; color: #101828; } .error { color: #d05060; }");
        gtk::style_context_add_provider_for_display(&gtk::gdk::Display::default().unwrap(),&css,gtk::STYLE_PROVIDER_PRIORITY_APPLICATION);
        let header=gtk::HeaderBar::new();header.set_title_widget(Some(&label("KeyStats","title")));window.set_titlebar(Some(&header));
        let period=gtk::DropDown::from_strings(&[&text(ja,"今日","Today"),&text(ja,"今週","This week"),&text(ja,"全期間","All time")]);header.pack_start(&period);
        let root=column();let toolbar=gtk::Box::new(gtk::Orientation::Horizontal,10);toolbar.set_margin_start(22);toolbar.set_margin_end(22);
        let status=label("","dim-label");status.set_hexpand(true);toolbar.append(&status);
        let summary=label("","dim-label");let reset=gtk::Button::with_label(&text(ja,"絞り込み解除","Clear filters"));toolbar.append(&summary);toolbar.append(&reset);root.append(&toolbar);
        let body=column();body.add_css_class("dashboard");let scroll=gtk::ScrolledWindow::builder().vexpand(true).hscrollbar_policy(gtk::PolicyType::Never).child(&body).build();root.append(&scroll);
        let ui=Ui{last_render:Rc::new(RefCell::new(String::new())),path:path.clone(),filter:Rc::new(RefCell::new(Filter::default())),body,status,summary,ja,layout:Rc::new(RefCell::new(config.layout)),period:Rc::new(RefCell::new("today".into()))};
        let u=ui.clone();period.connect_selected_notify(move|p|{*u.period.borrow_mut()=match p.selected(){1=>"week",2=>"all",_=>"today"}.into();u.refresh()});
        let u=ui.clone();reset.connect_clicked(move |_|{*u.filter.borrow_mut()=Filter::default();u.refresh()});
        let pause=gtk::ToggleButton::with_label(&text(ja,"収集を一時停止","Pause recording"));pause.set_active(config::paused());let parent=window.clone();let u=ui.clone();pause.connect_toggled(move|b|{if let Err(e)=config::pause(b.is_active()){error_dialog(&parent,&e.to_string())}u.refresh()});header.pack_end(&pause);
        let prefs=gtk::Button::from_icon_name("emblem-system-symbolic");prefs.set_tooltip_text(Some(&text(ja,"設定","Settings")));let parent=window.clone();let u=ui.clone();prefs.connect_clicked(move |_|settings(&parent,u.clone()));header.pack_end(&prefs);
        let export=gtk::Button::from_icon_name("document-save-symbolic");export.set_tooltip_text(Some("Export JSON"));let parent=window.clone();let u=ui.clone();export.connect_clicked(move |_|{
            let chooser=gtk::FileChooserNative::new(Some("Export JSON"),Some(&parent),gtk::FileChooserAction::Save,Some("Save"),Some("Cancel"));chooser.set_current_name("keystats.json");let u=u.clone();let parent=parent.clone();chooser.connect_response(move|c,response|{if response==gtk::ResponseType::Accept{if let Some(path)=c.file().and_then(|f|f.path()){let result=(||->Result<()>{let s=Store::read(&u.path)?.snapshot(&u.filter.borrow())?;use std::io::Write;let mut file=std::fs::OpenOptions::new().write(true).create_new(true).open(path)?;file.write_all(serde_json::to_string_pretty(&s)?.as_bytes())?;Ok(())})();if let Err(e)=result{error_dialog(&parent,&e.to_string())}}}c.destroy();});chooser.show();
        });header.pack_end(&export);
        window.set_child(Some(&root));ui.refresh();window.present();
        let weak=window.downgrade();glib::timeout_add_local(std::time::Duration::from_secs(2),move||{let Some(window)=weak.upgrade() else{return glib::ControlFlow::Break};
            if gtk::prelude::GtkWindowExt::focus(&window).is_some_and(|w|w.is_ancestor(&ui.body)){return glib::ControlFlow::Continue;}
            let position=scroll.vadjustment().value();ui.refresh();let adjustment=scroll.vadjustment();
            glib::idle_add_local_once(move||adjustment.set_value(position));glib::ControlFlow::Continue});
    });
    app.run_with_args::<&str>(&[]);
    Ok(())
}
