//! Settings declared as a Rust struct, and the manifest schema generated from
//! it.
//!
//! A plugin declares one group with [`crate::settings!`]:
//!
//! ```ignore
//! lookout::settings! {
//!     pub struct Display {
//!         group: "Downwind line",
//!         tab: Display,
//!         length_nm: Num {
//!             label: "Line length",
//!             desc: "How far downwind the line reaches.",
//!             unit: "nm", min: 0.1, max: 10.0, default: 1.0,
//!         },
//!     }
//! }
//! ```
//!
//! The macro writes the struct the plugin reads — `f64` for a `Num`, `bool`
//! for a `Flag` — with `Display::get()` handing back the live values, and the
//! `"settings"` object the manifest must carry. One declaration feeds both, so
//! a range cannot drift between the manifest and the code that clamps against
//! it.
//!
//! Nothing here calls the host, so `cargo test` checks a manifest against its
//! declaration on the development machine.

use crate::json::{self, Json};
use std::cell::UnsafeCell;

/// Most fields one plugin may declare, counting every group and every column.
pub const MAX_FIELDS: usize = 16;

/// Most rows one connection list holds.
pub const MAX_ROWS: usize = 8;

/// Longest text value the host keeps.
pub const MAX_TEXT_BYTES: usize = 128;

/// Where a group asks to be shown. The core owns these names; an unknown one
/// is not expressible, which is the point of the enum.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tab {
    Display,
    Depths,
    Text,
    Charts,
    Vessels,
    Alarms,
    Connections,
    Advanced,
}

impl Tab {
    pub fn text(self) -> &'static str {
        match self {
            Tab::Display => "display",
            Tab::Depths => "depths",
            Tab::Text => "text",
            Tab::Charts => "charts",
            Tab::Vessels => "vessels",
            Tab::Alarms => "alarms",
            Tab::Connections => "connections",
            Tab::Advanced => "advanced",
        }
    }
}

/// A number the mariner sets. `unit` is shown beside the control; the value
/// crosses the ABI in that unit and is clamped into the range before it
/// arrives.
#[derive(Debug, Clone, Copy)]
pub struct Num {
    pub label: &'static str,
    pub desc: &'static str,
    pub unit: &'static str,
    pub min: f64,
    pub max: f64,
    pub default: f64,
}

impl Num {
    /// What a declaration that names only some of the fields starts from.
    pub const DEFAULT: Num = Num {
        label: "",
        desc: "",
        unit: "",
        min: 0.0,
        max: 1.0,
        default: 0.0,
    };
}

/// An on/off switch.
#[derive(Debug, Clone, Copy)]
pub struct Flag {
    pub label: &'static str,
    pub desc: &'static str,
    pub default: bool,
}

impl Flag {
    pub const DEFAULT: Flag = Flag {
        label: "",
        desc: "",
        default: false,
    };
}

/// A line of text. Legal only as a column of a connection row: a scalar
/// setting crosses the ABI as a number and the host keeps no scalar string.
#[derive(Debug, Clone, Copy)]
pub struct Text {
    pub label: &'static str,
    pub desc: &'static str,
    pub default: &'static str,
    /// The mariner may leave it empty. An optional column declares no default.
    pub optional: bool,
}

impl Text {
    pub const DEFAULT: Text = Text {
        label: "",
        desc: "",
        default: "",
        optional: false,
    };
}

/// One field's metadata, whichever kind it is.
#[derive(Debug, Clone, Copy)]
pub enum Spec {
    Num(Num),
    Flag(Flag),
    Text(Text),
}

impl Spec {
    fn label(&self) -> &'static str {
        match self {
            Spec::Num(f) => f.label,
            Spec::Flag(f) => f.label,
            Spec::Text(f) => f.label,
        }
    }
    fn desc(&self) -> &'static str {
        match self {
            Spec::Num(f) => f.desc,
            Spec::Flag(f) => f.desc,
            Spec::Text(f) => f.desc,
        }
    }
}

/// One declared field: its config key and its metadata.
#[derive(Debug, Clone, Copy)]
pub struct Field {
    pub key: &'static str,
    pub spec: Spec,
}

/// What one kind of field holds and how it reads a config value.
pub trait FieldSpec: Copy + 'static {
    /// The plain Rust type the plugin reads.
    type Value: Clone + PartialEq + std::fmt::Debug;
    fn value_default(&self) -> Self::Value;
    /// Take a value the host sent. A value of the wrong type is refused rather
    /// than coerced: a toggle sent as a number is a shell with a bug.
    fn read_into(&self, v: &Json<'_>, out: &mut Self::Value);
}

impl FieldSpec for Num {
    type Value = f64;
    fn value_default(&self) -> f64 {
        self.default
    }
    fn read_into(&self, v: &Json<'_>, out: &mut f64) {
        if let Some(n) = v.as_f64() {
            *out = n.clamp(self.min, self.max);
        }
    }
}

impl FieldSpec for Flag {
    type Value = bool;
    fn value_default(&self) -> bool {
        self.default
    }
    fn read_into(&self, v: &Json<'_>, out: &mut bool) {
        if let Some(b) = v.as_bool() {
            *out = b;
        }
    }
}

impl FieldSpec for Text {
    type Value = String;
    fn value_default(&self) -> String {
        self.default.to_owned()
    }
    fn read_into(&self, v: &Json<'_>, out: &mut String) {
        if let Some(s) = v.as_str() {
            out.clear();
            out.push_str(&s[..s.len().min(MAX_TEXT_BYTES)]);
        }
    }
}

/// A struct of declared fields: a settings group, or the extra columns of a
/// connection row. [`crate::settings!`] and [`crate::columns!`] write it.
pub trait Fields: Default + Clone + PartialEq + 'static {
    const FIELDS: &'static [Field];
    /// Read the keys this object carries and leave the rest, so a partial
    /// object is a partial update rather than a reset to defaults.
    fn read(&mut self, cfg: &Json<'_>);
}

/// A row with no columns of its own.
impl Fields for () {
    const FIELDS: &'static [Field] = &[];
    fn read(&mut self, _cfg: &Json<'_>) {}
}

/// The live values of one settings group. One per group type, written by the
/// macro; a plugin reads it through `Group::get()`.
///
/// A global with no lock. Sound here and nowhere else: wasm32 without the
/// threads proposal has exactly one thread, and the host contract is one call
/// into the module at a time.
pub struct Store<T>(UnsafeCell<Option<T>>);

unsafe impl<T> Sync for Store<T> {}

impl<T: Fields> Default for Store<T> {
    fn default() -> Self {
        Self::new()
    }
}

impl<T: Fields> Store<T> {
    pub const fn new() -> Store<T> {
        Store(UnsafeCell::new(None))
    }

    #[allow(clippy::mut_from_ref)]
    fn slot(&self) -> &mut T {
        let opt = unsafe { &mut *self.0.get() };
        opt.get_or_insert_with(T::default)
    }

    pub fn get(&self) -> T {
        self.slot().clone()
    }

    pub fn read(&self, cfg: &Json<'_>) {
        self.slot().read(cfg);
    }
}

/// One settings group: fields, a heading and the tab it asks for.
pub trait SettingsGroup: Fields {
    const LABEL: &'static str;
    const TAB: Tab;

    /// Where the live values are kept. The macro writes this.
    fn store() -> &'static Store<Self>;

    /// The current value of every setting in the group.
    fn get() -> Self {
        Self::store().get()
    }

    /// Take the host's config object. The library calls this at start and on
    /// every change.
    fn apply(cfg: &Json<'_>) {
        Self::store().read(cfg);
    }

    /// This group's entry in the manifest's settings schema.
    fn schema() -> Group {
        Group {
            label: Self::LABEL.to_owned(),
            tab: Self::TAB,
            fields: Self::FIELDS.to_vec(),
            list: None,
        }
    }
}

/// One settings group as the library holds it: how to update it, and what it
/// declares. `SettingsHook::of::<Group>()` builds it.
#[derive(Clone, Copy)]
pub struct SettingsHook {
    pub(crate) apply: fn(&Json<'_>),
    pub(crate) schema: fn() -> Group,
}

impl SettingsHook {
    pub const fn of<G: SettingsGroup>() -> SettingsHook {
        // A text setting is legal only as a connection column, because the
        // host keeps no scalar string. The check is const, so it fails the
        // build rather than the boat.
        let fields = G::FIELDS;
        let mut i = 0;
        while i < fields.len() {
            if let Spec::Text(_) = fields[i].spec {
                panic!(
                    "a text setting is legal only as a column of a connection row: \
                     the host keeps no scalar string"
                );
            }
            i += 1;
        }
        SettingsHook {
            apply: G::apply,
            schema: G::schema,
        }
    }

    /// This group's entry in the manifest's settings schema, for the plugin's
    /// own manifest test.
    pub fn group(&self) -> Group {
        (self.schema)()
    }
}

/// The list metadata of a connection group.
#[derive(Debug, Clone)]
pub struct ListInfo {
    /// The config key the row array arrives under.
    pub key: String,
    pub footer: String,
    pub empty: String,
    pub add_label: String,
    /// Which toggle column is the row's own switch.
    pub switch_key: String,
}

/// One group of the manifest's `"settings"` object.
#[derive(Debug, Clone)]
pub struct Group {
    pub label: String,
    pub tab: Tab,
    pub fields: Vec<Field>,
    /// Set for a connection list; `fields` is then the row's columns.
    pub list: Option<ListInfo>,
}

/// The `"settings"` value a manifest must carry for these groups.
pub fn settings_json(groups: &[Group]) -> String {
    let mut out = String::from("{\"groups\":[");
    let mut total = 0;
    for (i, g) in groups.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        total += g.fields.len();
        out.push('{');
        out.push_str("\"label\":");
        json::push_str(&mut out, &g.label);
        out.push_str(",\"tab\":\"");
        out.push_str(g.tab.text());
        out.push('"');
        match &g.list {
            None => {
                out.push_str(",\"fields\":[");
                fields_json(&mut out, &g.fields);
                out.push(']');
            }
            Some(list) => {
                out.push_str(",\"list\":{\"key\":");
                json::push_str(&mut out, &list.key);
                for (key, value) in [
                    ("footer", &list.footer),
                    ("empty", &list.empty),
                    ("add_label", &list.add_label),
                ] {
                    if !value.is_empty() {
                        out.push_str(&format!(",\"{}\":", key));
                        json::push_str(&mut out, value);
                    }
                }
                out.push_str(",\"switch_key\":");
                json::push_str(&mut out, &list.switch_key);
                out.push_str(",\"item_fields\":[");
                fields_json(&mut out, &g.fields);
                out.push_str("]}");
            }
        }
        out.push('}');
    }
    out.push_str("]}");
    if total > MAX_FIELDS {
        crate::log!(
            crate::raw::Level::Warn,
            "the settings schema declares {} fields; the host allows {}",
            total,
            MAX_FIELDS
        );
    }
    out
}

fn fields_json(out: &mut String, fields: &[Field]) {
    for (i, f) in fields.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        out.push_str("{\"key\":");
        json::push_str(out, f.key);
        out.push_str(",\"label\":");
        json::push_str(out, f.spec.label());
        if !f.spec.desc().is_empty() {
            out.push_str(",\"desc\":");
            json::push_str(out, f.spec.desc());
        }
        match f.spec {
            Spec::Num(n) => {
                out.push_str(",\"kind\":\"number\"");
                if !n.unit.is_empty() {
                    out.push_str(",\"unit\":");
                    json::push_str(out, n.unit);
                }
                out.push_str(",\"min\":");
                json::push_num(out, n.min);
                out.push_str(",\"max\":");
                json::push_num(out, n.max);
                out.push_str(",\"default\":");
                json::push_num(out, n.default);
            }
            Spec::Flag(b) => {
                out.push_str(",\"kind\":\"toggle\",\"default\":");
                out.push_str(if b.default { "true" } else { "false" });
            }
            // An optional column declares no default: the shell says the
            // mariner may leave it empty, and empty is what the plugin reads.
            Spec::Text(t) => {
                out.push_str(",\"kind\":\"text\"");
                if t.optional {
                    out.push_str(",\"optional\":true");
                } else {
                    out.push_str(",\"default\":");
                    json::push_str(out, t.default);
                }
            }
        }
        out.push('}');
    }
}

/// Fail when the manifest's `"settings"` is not the schema these groups
/// generate. Both sides are parsed, so key order and whitespace do not matter;
/// everything else does.
///
/// For a plugin's own test:
///
/// ```ignore
/// #[test]
/// fn the_manifest_carries_the_schema_the_settings_struct_declares() {
///     lookout::expect_manifest(include_str!("../manifest.json"), &[Display::schema()]).unwrap();
/// }
/// ```
pub fn expect_manifest(manifest_text: &str, groups: &[Group]) -> Result<(), String> {
    let want_text = settings_json(groups);
    let manifest = Json::parse(manifest_text).ok_or("the manifest is not JSON")?;
    let got = manifest.get("settings").ok_or_else(|| {
        format!(
            "the manifest declares no settings; the struct declares:\n{}",
            want_text
        )
    })?;
    let want = Json::parse(&want_text).ok_or("the generated schema is not JSON")?;
    if !equal(got, &want) {
        return Err(format!(
            "manifest settings do not match the settings struct.\nthe struct declares:\n{}",
            want_text
        ));
    }
    Ok(())
}

/// Deep equality over parsed JSON. Numbers compare by value, so 926 and 926.0
/// are the same schema.
fn equal(a: &Json<'_>, b: &Json<'_>) -> bool {
    match (a, b) {
        (Json::Null, Json::Null) => true,
        (Json::Bool(x), Json::Bool(y)) => x == y,
        (Json::Num(x), Json::Num(y)) => x == y,
        (Json::Str(x), Json::Str(y)) => x == y,
        (Json::Arr(x), Json::Arr(y)) => {
            x.len() == y.len() && x.iter().zip(y.iter()).all(|(i, j)| equal(i, j))
        }
        (Json::Obj(x), Json::Obj(y)) => {
            x.len() == y.len()
                && x.iter()
                    .all(|(k, v)| y.iter().any(|(k2, v2)| k == k2 && equal(v, v2)))
        }
        _ => false,
    }
}

/// Write the struct, its defaults and its `Fields` impl. `settings!` and
/// `columns!` both go through here; there is nothing to call by hand.
#[doc(hidden)]
#[macro_export]
macro_rules! __fields {
    (
        $(#[$meta:meta])*
        $vis:vis struct $name:ident {
            $( $(#[$fmeta:meta])* $key:ident : $kind:ident { $($fk:ident : $fv:expr),* } ),*
        }
    ) => {
        $(#[$meta])*
        #[derive(Clone, Debug, PartialEq)]
        $vis struct $name {
            $( $(#[$fmeta])* pub $key: <$crate::$kind as $crate::FieldSpec>::Value, )*
        }

        impl ::core::default::Default for $name {
            fn default() -> Self {
                Self {
                    $( $key: $crate::FieldSpec::value_default(
                        &$crate::$kind { $($fk: $fv,)* ..$crate::$kind::DEFAULT }
                    ), )*
                }
            }
        }

        impl $crate::Fields for $name {
            const FIELDS: &'static [$crate::Field] = &[
                $( $crate::Field {
                    key: stringify!($key),
                    spec: $crate::Spec::$kind($crate::$kind { $($fk: $fv,)* ..$crate::$kind::DEFAULT }),
                }, )*
            ];

            fn read(&mut self, cfg: &$crate::Json<'_>) {
                $( if let Some(v) = cfg.get(stringify!($key)) {
                    $crate::FieldSpec::read_into(
                        &$crate::$kind { $($fk: $fv,)* ..$crate::$kind::DEFAULT },
                        v,
                        &mut self.$key,
                    );
                } )*
            }
        }
    };
}

/// Declare one settings group: the struct the plugin reads, and the schema the
/// manifest must carry.
///
/// ```ignore
/// lookout::settings! {
///     pub struct Alarm {
///         group: "Collision alarm",
///         tab: Alarms,
///         cpa_limit: Num { label: "Closest approach (CPA)", unit: "m",
///                          min: 93.0, max: 9260.0, default: 926.0 },
///         cpa_alarm: Flag { label: "Collision alarm", default: true },
///     }
/// }
/// ```
///
/// `Alarm::get()` is the live values, `Alarm::schema()` the manifest entry.
/// List the group in `Plugin::SETTINGS` and the library parses the host's
/// config into it.
#[macro_export]
macro_rules! settings {
    (
        $(#[$meta:meta])*
        $vis:vis struct $name:ident {
            group: $group:expr,
            tab: $tab:ident,
            $( $(#[$fmeta:meta])* $key:ident : $kind:ident { $($fk:ident : $fv:expr),* $(,)? } ),* $(,)?
        }
    ) => {
        $crate::__fields! {
            $(#[$meta])*
            $vis struct $name {
                $( $(#[$fmeta])* $key : $kind { $($fk : $fv),* } ),*
            }
        }

        impl $crate::SettingsGroup for $name {
            const LABEL: &'static str = $group;
            const TAB: $crate::Tab = $crate::Tab::$tab;

            fn store() -> &'static $crate::Store<Self> {
                static STORE: $crate::Store<$name> = $crate::Store::new();
                &STORE
            }
        }

        impl $name {
            /// The live values of this group.
            pub fn get() -> $name {
                <$name as $crate::SettingsGroup>::get()
            }

            /// This group's entry in the manifest's settings schema.
            pub fn schema() -> $crate::Group {
                <$name as $crate::SettingsGroup>::schema()
            }
        }
    };
}

/// Declare the columns of a connection row beyond the four every list carries.
/// `Text` is legal here and nowhere else.
///
/// ```ignore
/// lookout::columns! {
///     pub struct SkColumns {
///         websocket: Flag { label: "WebSocket", default: false },
///     }
/// }
/// ```
#[macro_export]
macro_rules! columns {
    (
        $(#[$meta:meta])*
        $vis:vis struct $name:ident {
            $( $(#[$fmeta:meta])* $key:ident : $kind:ident { $($fk:ident : $fv:expr),* $(,)? } ),* $(,)?
        }
    ) => {
        $crate::__fields! {
            $(#[$meta])*
            $vis struct $name {
                $( $(#[$fmeta])* $key : $kind { $($fk : $fv),* } ),*
            }
        }
    };
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate as lookout;

    crate::settings! {
        pub struct Alarm {
            group: "Collision alarm",
            tab: Alarms,
            cpa_limit: Num {
                label: "Closest approach (CPA)",
                desc: "Alarm when a vessel will pass closer than this.",
                unit: "m", min: 93.0, max: 9260.0, default: 926.0,
            },
            cpa_alarm: Flag {
                label: "Collision alarm",
                desc: "Sound the alarm and colour the vessel red. Off silences both.",
                default: true,
            },
        }
    }

    #[test]
    fn the_values_struct_carries_plain_types_at_the_declared_defaults() {
        let v = Alarm::default();
        assert_eq!(v.cpa_limit, 926.0);
        assert!(v.cpa_alarm);
    }

    #[test]
    fn a_config_object_updates_the_keys_it_carries_and_leaves_the_rest() {
        let cfg = Json::parse(r#"{"cpa_limit":1500}"#).unwrap();
        let mut v = Alarm::default();
        v.read(&cfg);
        assert_eq!(v.cpa_limit, 1500.0);
        assert!(v.cpa_alarm);
    }

    #[test]
    fn a_number_outside_the_declared_range_is_clamped_not_taken() {
        let cfg = Json::parse(r#"{"cpa_limit":99999,"cpa_alarm":42}"#).unwrap();
        let mut v = Alarm::default();
        v.read(&cfg);
        assert_eq!(v.cpa_limit, 9260.0);
        // A toggle sent as a number is a shell with the wrong type, and is
        // refused rather than coerced.
        assert!(v.cpa_alarm);
    }

    #[test]
    fn the_generated_schema_is_the_manifest_the_ais_plugin_ships() {
        let want = r#"{"groups":[{"label":"Collision alarm","tab":"alarms","fields":[
            {"key":"cpa_limit","label":"Closest approach (CPA)","desc":"Alarm when a vessel will pass closer than this.","kind":"number","unit":"m","min":93,"max":9260,"default":926},
            {"key":"cpa_alarm","label":"Collision alarm","desc":"Sound the alarm and colour the vessel red. Off silences both.","kind":"toggle","default":true}]}]}"#;
        let got = settings_json(&[Alarm::schema()]);
        assert!(
            equal(&Json::parse(&got).unwrap(), &Json::parse(want).unwrap()),
            "{}",
            got
        );
    }

    crate::settings! {
        struct Bare {
            group: "",
            tab: Advanced,
            scale: Num { label: "Size", min: 0.5, max: 3.0, default: 1.0 },
        }
    }

    #[test]
    fn a_group_with_no_desc_leaves_it_out() {
        assert_eq!(
            settings_json(&[Bare::schema()]),
            "{\"groups\":[{\"label\":\"\",\"tab\":\"advanced\",\"fields\":[\
             {\"key\":\"scale\",\"label\":\"Size\",\"kind\":\"number\",\
             \"min\":0.5,\"max\":3,\"default\":1}]}]}"
        );
    }

    #[test]
    fn the_manifest_is_checked_against_the_declaration() {
        let manifest = format!(
            r#"{{"id":"org.example.x","abi":1,"settings":{}}}"#,
            settings_json(&[Bare::schema()])
        );
        assert!(expect_manifest(&manifest, &[Bare::schema()]).is_ok());
        assert!(expect_manifest(r#"{"id":"x"}"#, &[Bare::schema()]).is_err());
        assert!(expect_manifest(
            r#"{"settings":{"groups":[{"label":"","tab":"advanced","fields":[]}]}}"#,
            &[Bare::schema()]
        )
        .is_err());
    }

    crate::columns! {
        pub struct SkColumns {
            websocket: Flag { label: "WebSocket", default: false },
            token: Text { label: "Token", optional: true },
        }
    }

    #[test]
    fn a_text_column_reads_a_string_and_refuses_a_number() {
        let mut c = SkColumns::default();
        c.read(&Json::parse(r#"{"token":"abc","websocket":true}"#).unwrap());
        assert_eq!(c.token, "abc");
        assert!(c.websocket);
        c.read(&Json::parse(r#"{"token":7}"#).unwrap());
        assert_eq!(c.token, "abc");
    }

    #[test]
    fn the_live_store_starts_at_the_defaults_and_takes_a_change() {
        assert_eq!(Alarm::get().cpa_limit, 926.0);
        <Alarm as SettingsGroup>::apply(&Json::parse(r#"{"cpa_limit":1200}"#).unwrap());
        assert_eq!(Alarm::get().cpa_limit, 1200.0);
        <Alarm as SettingsGroup>::apply(&Json::parse(r#"{"cpa_limit":926}"#).unwrap());
    }
}
