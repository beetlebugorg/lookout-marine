//! Just enough JSON for the ABI: a borrowing reader and the escaping a writer
//! needs. The SDK has no dependencies, so this is here instead of serde.
//!
//! The reader borrows from the input wherever it can. A string with no escape
//! in it costs nothing; one with an escape is copied once. That matters: a
//! STORE_CHANGED payload arrives up to ten times a second.

use std::borrow::Cow;

/// A parsed JSON value. It borrows from the text it was parsed from, so it
/// lives no longer than the event payload does.
#[derive(Debug, Clone, PartialEq)]
pub enum Json<'a> {
    Null,
    Bool(bool),
    Num(f64),
    Str(Cow<'a, str>),
    Arr(Vec<Json<'a>>),
    Obj(Vec<(Cow<'a, str>, Json<'a>)>),
}

impl<'a> Json<'a> {
    /// Parse a whole document. Trailing text after the value is an error, so a
    /// truncated payload does not read as a valid short one.
    pub fn parse(text: &'a str) -> Option<Json<'a>> {
        let mut p = Parser {
            b: text.as_bytes(),
            s: text,
            i: 0,
        };
        let v = p.value()?;
        p.ws();
        if p.i == p.b.len() {
            Some(v)
        } else {
            None
        }
    }

    /// One member of an object, or nothing.
    pub fn get(&self, key: &str) -> Option<&Json<'a>> {
        match self {
            Json::Obj(m) => m.iter().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }

    pub fn as_str(&self) -> Option<&str> {
        match self {
            Json::Str(s) => Some(s.as_ref()),
            _ => None,
        }
    }

    /// The string with the lifetime of the parsed text rather than of this
    /// node, so it can outlive the tree it came out of. Free for a string with
    /// no escape in it, which is nearly all of them; a copy for the rest.
    pub fn as_cow(&self) -> Option<Cow<'a, str>> {
        match self {
            Json::Str(s) => Some(s.clone()),
            _ => None,
        }
    }

    pub fn as_f64(&self) -> Option<f64> {
        match self {
            Json::Num(n) => Some(*n),
            _ => None,
        }
    }

    pub fn as_i64(&self) -> Option<i64> {
        self.as_f64().map(|n| n as i64)
    }

    pub fn as_bool(&self) -> Option<bool> {
        match self {
            Json::Bool(b) => Some(*b),
            _ => None,
        }
    }

    pub fn as_array(&self) -> Option<&[Json<'a>]> {
        match self {
            Json::Arr(v) => Some(v.as_slice()),
            _ => None,
        }
    }

    pub fn is_null(&self) -> bool {
        matches!(self, Json::Null)
    }

    /// A string member, or `fallback`.
    pub fn str_or<'b>(&'b self, key: &str, fallback: &'b str) -> &'b str {
        self.get(key).and_then(Json::as_str).unwrap_or(fallback)
    }

    /// An integer member, or `fallback`.
    pub fn i64_or(&self, key: &str, fallback: i64) -> i64 {
        self.get(key).and_then(Json::as_i64).unwrap_or(fallback)
    }

    /// A number member, or `fallback`.
    pub fn f64_or(&self, key: &str, fallback: f64) -> f64 {
        self.get(key).and_then(Json::as_f64).unwrap_or(fallback)
    }

    /// A boolean member, or `fallback`.
    pub fn bool_or(&self, key: &str, fallback: bool) -> bool {
        self.get(key).and_then(Json::as_bool).unwrap_or(fallback)
    }
}

struct Parser<'a> {
    b: &'a [u8],
    s: &'a str,
    i: usize,
}

impl<'a> Parser<'a> {
    fn ws(&mut self) {
        while self.i < self.b.len() && matches!(self.b[self.i], b' ' | b'\t' | b'\n' | b'\r') {
            self.i += 1;
        }
    }

    fn eat(&mut self, c: u8) -> Option<()> {
        if self.i < self.b.len() && self.b[self.i] == c {
            self.i += 1;
            Some(())
        } else {
            None
        }
    }

    fn lit(&mut self, word: &str) -> Option<()> {
        if self.s[self.i..].starts_with(word) {
            self.i += word.len();
            Some(())
        } else {
            None
        }
    }

    fn value(&mut self) -> Option<Json<'a>> {
        self.ws();
        match *self.b.get(self.i)? {
            b'n' => self.lit("null").map(|_| Json::Null),
            b't' => self.lit("true").map(|_| Json::Bool(true)),
            b'f' => self.lit("false").map(|_| Json::Bool(false)),
            b'"' => self.string().map(Json::Str),
            b'[' => self.array(),
            b'{' => self.object(),
            _ => self.number(),
        }
    }

    fn array(&mut self) -> Option<Json<'a>> {
        self.eat(b'[')?;
        let mut out = Vec::new();
        self.ws();
        if self.eat(b']').is_some() {
            return Some(Json::Arr(out));
        }
        loop {
            out.push(self.value()?);
            self.ws();
            if self.eat(b',').is_some() {
                continue;
            }
            self.eat(b']')?;
            return Some(Json::Arr(out));
        }
    }

    fn object(&mut self) -> Option<Json<'a>> {
        self.eat(b'{')?;
        let mut out = Vec::new();
        self.ws();
        if self.eat(b'}').is_some() {
            return Some(Json::Obj(out));
        }
        loop {
            self.ws();
            let k = self.string()?;
            self.ws();
            self.eat(b':')?;
            let v = self.value()?;
            out.push((k, v));
            self.ws();
            if self.eat(b',').is_some() {
                continue;
            }
            self.eat(b'}')?;
            return Some(Json::Obj(out));
        }
    }

    fn string(&mut self) -> Option<Cow<'a, str>> {
        self.eat(b'"')?;
        let start = self.i;
        // The common case first: scan for the closing quote and borrow.
        while self.i < self.b.len() {
            match self.b[self.i] {
                b'"' => {
                    let s = self.s.get(start..self.i)?;
                    self.i += 1;
                    return Some(Cow::Borrowed(s));
                }
                b'\\' => break,
                _ => self.i += 1,
            }
        }
        if self.i >= self.b.len() {
            return None;
        }
        // An escape: copy from here on.
        let mut out = String::from(self.s.get(start..self.i)?);
        while self.i < self.b.len() {
            match self.b[self.i] {
                b'"' => {
                    self.i += 1;
                    return Some(Cow::Owned(out));
                }
                b'\\' => {
                    self.i += 1;
                    let c = *self.b.get(self.i)?;
                    self.i += 1;
                    match c {
                        b'"' => out.push('"'),
                        b'\\' => out.push('\\'),
                        b'/' => out.push('/'),
                        b'b' => out.push('\u{8}'),
                        b'f' => out.push('\u{c}'),
                        b'n' => out.push('\n'),
                        b'r' => out.push('\r'),
                        b't' => out.push('\t'),
                        b'u' => {
                            let hex = self.s.get(self.i..self.i + 4)?;
                            self.i += 4;
                            let n = u32::from_str_radix(hex, 16).ok()?;
                            // A lone surrogate is not text. The replacement
                            // character keeps the parse going instead of
                            // dropping the whole payload.
                            out.push(char::from_u32(n).unwrap_or('\u{fffd}'));
                        }
                        _ => return None,
                    }
                }
                _ => {
                    let c = self.s[self.i..].chars().next()?;
                    out.push(c);
                    self.i += c.len_utf8();
                }
            }
        }
        None
    }

    fn number(&mut self) -> Option<Json<'a>> {
        let start = self.i;
        if self.i < self.b.len() && (self.b[self.i] == b'-' || self.b[self.i] == b'+') {
            self.i += 1;
        }
        while self.i < self.b.len()
            && matches!(
                self.b[self.i],
                b'0'..=b'9' | b'.' | b'e' | b'E' | b'+' | b'-'
            )
        {
            self.i += 1;
        }
        if self.i == start {
            return None;
        }
        self.s
            .get(start..self.i)?
            .parse::<f64>()
            .ok()
            .map(Json::Num)
    }
}

/// Append `s` to `out` as a quoted, escaped JSON string.
pub fn push_str(out: &mut String, s: &str) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => {
                out.push_str(&format!("\\u{:04x}", c as u32));
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

/// Append a finite number, or `null`. An infinity or a NaN in a payload is a
/// bug the host would reject, so it never leaves here.
pub fn push_num(out: &mut String, v: f64) {
    if v.is_finite() {
        out.push_str(&format!("{}", v));
    } else {
        out.push_str("null");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_a_store_payload() {
        let text = r#"{"values":[{"path":"navigation.position","value":{"lat":38.9,"lon":-76.4},"ts":17,"age_ms":3}]}"#;
        let v = Json::parse(text).expect("parses");
        let values = v.get("values").unwrap().as_array().unwrap();
        assert_eq!(values.len(), 1);
        assert_eq!(values[0].str_or("path", ""), "navigation.position");
        assert_eq!(values[0].get("value").unwrap().f64_or("lat", 0.0), 38.9);
        assert_eq!(values[0].i64_or("age_ms", -1), 3);
    }

    #[test]
    fn borrows_a_plain_string_and_copies_an_escaped_one() {
        let v = Json::parse(r#"{"a":"plain","b":"one\ntwo"}"#).unwrap();
        assert!(matches!(
            v.get("a"),
            Some(Json::Str(Cow::Borrowed("plain")))
        ));
        assert_eq!(v.str_or("b", ""), "one\ntwo");
    }

    #[test]
    fn refuses_trailing_text_and_truncation() {
        assert!(Json::parse("{} junk").is_none());
        assert!(Json::parse(r#"{"a":"#).is_none());
        assert!(Json::parse(r#"{"a":"unterminated"#).is_none());
    }

    #[test]
    fn writes_escaped_text_and_refuses_infinities() {
        let mut s = String::new();
        push_str(&mut s, "he said \"go\"\n");
        assert_eq!(s, r#""he said \"go\"\n""#);
        let mut n = String::new();
        push_num(&mut n, f64::NAN);
        push_num(&mut n, 1.5);
        assert_eq!(n, "null1.5");
    }
}
