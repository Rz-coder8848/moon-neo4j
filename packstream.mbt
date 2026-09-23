///|
/// PackStream — the binary serialization format of the Neo4j Bolt protocol.
///
/// This module is a pure, dependency-free implementation of the PackStream
/// codec: a value model ([`PackStreamValue`]) plus an encoder
/// ([`packstream_encode`]) and a decoder ([`packstream_decode`]). No network,
/// no IO — everything here is unit-testable in isolation.
///
/// Marker summary (see https://neo4j.com/docs/bolt/current/packstream/):
///
/// * `0xC0` Null, `0xC1` Float64, `0xC2` False, `0xC3` True
/// * Integer: a single signed byte `0x00..0x7F` / `0xF0..0xFF` (tiny, -16..127),
///   then `0xC8` / `0xC9` / `0xCA` / `0xCB` (INT_8/16/32/64)
/// * String: `0x80..0x8F` (tiny, 0-15 bytes) or `0xD0` / `0xD1` / `0xD2` (8/16/32)
/// * List: `0x90..0x9F` or `0xD4` / `0xD5` / `0xD6`
/// * Map: `0xA0..0xAF` or `0xD8` / `0xD9` / `0xDA`
/// * Struct: `0xB0..0xBF` or `0xDC` / `0xDD` (tag byte + fields)
/// * Bytes: `0xCC` / `0xCD` / `0xCE` (8/16/32 length)

///|
/// A PackStream value. Maps are kept as an ordered list of `(String, value)`
/// pairs so insertion order is preserved exactly as sent on the wire.
pub enum PackStreamValue {
  Null
  Bool(Bool)
  Int(Int64)
  Float(Double)
  Str(String)
  List(Array[PackStreamValue])
  Map(Array[(String, PackStreamValue)])
  Struct(Int, Array[PackStreamValue])
  Bytes(Bytes)
} derive(Eq, @debug.Debug)

///|
pub fn PackStreamValue::null() -> PackStreamValue {
  PackStreamValue::Null
}

///|
pub fn PackStreamValue::bool(b : Bool) -> PackStreamValue {
  PackStreamValue::Bool(b)
}

///|
pub fn PackStreamValue::int(i : Int64) -> PackStreamValue {
  PackStreamValue::Int(i)
}

///|
/// Convenience constructor for a 32-bit integer value.
pub fn PackStreamValue::int32(i : Int) -> PackStreamValue {
  PackStreamValue::Int(i.to_int64())
}

///|
pub fn PackStreamValue::float(d : Double) -> PackStreamValue {
  PackStreamValue::Float(d)
}

///|
pub fn PackStreamValue::str(s : String) -> PackStreamValue {
  PackStreamValue::Str(s)
}

///|
pub fn PackStreamValue::list(items : Array[PackStreamValue]) -> PackStreamValue {
  PackStreamValue::List(items)
}

///|
pub fn PackStreamValue::map(
  entries : Array[(String, PackStreamValue)],
) -> PackStreamValue {
  PackStreamValue::Map(entries)
}

///|
/// `tag` is the single-byte struct signature; it must be in `0..=255`.
pub fn PackStreamValue::struct_(
  tag : Int,
  fields : Array[PackStreamValue],
) -> PackStreamValue {
  PackStreamValue::Struct(tag, fields)
}

///|
pub fn PackStreamValue::bytes(b : Bytes) -> PackStreamValue {
  PackStreamValue::Bytes(b)
}

///|
/// Render a value in a human-readable form: strings unquoted, numbers and
/// booleans as literals, lists/maps rendered recursively, and structs/bytes as
/// a short summary. This [`Show`] instance is what `println` uses.
pub impl Show for PackStreamValue with fn to_string(self) -> String {
  match self {
    Null => "null"
    Bool(b) => if b { "true" } else { "false" }
    Int(i) => i.to_string()
    Float(f) => f.to_string()
    Str(s) => s
    List(items) => {
      let parts = []
      for item in items {
        parts.push(item.to_string())
      }
      "[" + parts.join(", ") + "]"
    }
    Map(entries) => {
      let parts = []
      for (k, v) in entries {
        parts.push(k + ": " + v.to_string())
      }
      "{" + parts.join(", ") + "}"
    }
    Struct(tag, _) => "struct(" + tag.to_string() + ")"
    Bytes(b) => "bytes(" + b.length().to_string() + ")"
  }
}

///|
/// Promote `to_string` to a regular method so `value.to_string()` needs no
/// explicit `Show` qualification.
pub extend PackStreamValue with Show::{to_string}

///|
/// Encode a [`PackStreamValue`] to its PackStream byte representation.
pub fn packstream_encode(value : PackStreamValue) -> Bytes {
  let w = Writer::new()
  w.write(value)
  w.to_bytes()
}

///|
/// Decode a single PackStream value from `bytes`.
///
/// Returns `None` when the bytes do not hold exactly one well-formed value
/// (truncated input, an unknown marker, or trailing garbage).
pub fn packstream_decode(bytes : Bytes) -> PackStreamValue? {
  let r = Reader::new(bytes)
  match r.read() {
    None => None
    Some(value) => if r.eof() { Some(value) } else { None }
  }
}

///|
/// Write `value` into `buf`.
fn write_value(buf : Buffer, value : PackStreamValue) -> Unit {
  match value {
    Null => buf.write_byte(b'\xc0')
    Bool(b) => buf.write_byte(if b { b'\xc3' } else { b'\xc2' })
    Int(i) => write_int(buf, i)
    Float(d) => {
      buf.write_byte(b'\xc1')
      buf.write_double_be(d)
    }
    Str(s) => write_string(buf, s)
    List(items) => write_list(buf, items)
    Map(entries) => write_map(buf, entries)
    Struct(tag, fields) => write_struct(buf, tag, fields)
    Bytes(b) => write_bytes_value(buf, b)
  }
}

///|
/// Write a 64-bit integer using the most compact marker.
fn write_int(buf : Buffer, i : Int64) -> Unit {
  if i >= -16L && i <= 127L {
    buf.write_byte(i.to_byte())
  } else if i >= -128L && i <= 127L {
    buf.write_byte(b'\xc8')
    buf.write_byte(i.to_byte())
  } else if i >= -32768L && i <= 32767L {
    buf.write_byte(b'\xc9')
    buf.write_int16_be(Int16::from_int64(i))
  } else if i >= -2147483648L && i <= 2147483647L {
    buf.write_byte(b'\xca')
    buf.write_int_be(i.to_int())
  } else {
    buf.write_byte(b'\xcb')
    buf.write_int64_be(i)
  }
}

///|
/// Write the tiny/8/16/32-bit length marker shared by String, List and Map.
fn write_sized_marker(
  buf : Buffer,
  n : Int,
  tiny : Int,
  m8 : Int,
  m16 : Int,
  m32 : Int,
) -> Unit {
  if n <= 15 {
    buf.write_byte((tiny + n).to_byte())
  } else if n <= 255 {
    buf.write_byte(m8.to_byte())
    buf.write_byte(n.to_byte())
  } else if n <= 65535 {
    buf.write_byte(m16.to_byte())
    buf.write_int16_be(Int16::from_int(n))
  } else {
    buf.write_byte(m32.to_byte())
    buf.write_int_be(n)
  }
}

///|
/// Write a Bytes length marker (`0xCC` / `0xCD` / `0xCE`; Bytes has no tiny form).
fn write_bytes_marker(buf : Buffer, n : Int) -> Unit {
  if n <= 255 {
    buf.write_byte(b'\xcc')
    buf.write_byte(n.to_byte())
  } else if n <= 65535 {
    buf.write_byte(b'\xcd')
    buf.write_int16_be(Int16::from_int(n))
  } else {
    buf.write_byte(b'\xce')
    buf.write_int_be(n)
  }
}

///|
/// Write a Struct length marker (`0xB0..0xBF` / `0xDC` / `0xDD`).
fn write_struct_marker(buf : Buffer, n : Int) -> Unit {
  if n <= 15 {
    buf.write_byte((0xB0 + n).to_byte())
  } else if n <= 255 {
    buf.write_byte(b'\xdc')
    buf.write_byte(n.to_byte())
  } else {
    buf.write_byte(b'\xdd')
    buf.write_int16_be(Int16::from_int(n))
  }
}

///|
fn write_string(buf : Buffer, s : String) -> Unit {
  let utf8 = @utf8.encode(s.to_string_view())
  write_sized_marker(buf, utf8.length(), 0x80, 0xD0, 0xD1, 0xD2)
  buf.write_bytes(utf8.exact_view())
}

///|
fn write_list(buf : Buffer, items : Array[PackStreamValue]) -> Unit {
  write_sized_marker(buf, items.length(), 0x90, 0xD4, 0xD5, 0xD6)
  for item in items {
    write_value(buf, item)
  }
}

///|
fn write_map(buf : Buffer, entries : Array[(String, PackStreamValue)]) -> Unit {
  write_sized_marker(buf, entries.length(), 0xA0, 0xD8, 0xD9, 0xDA)
  for (k, v) in entries {
    write_string(buf, k)
    write_value(buf, v)
  }
}

///|
fn write_struct(
  buf : Buffer,
  tag : Int,
  fields : Array[PackStreamValue],
) -> Unit {
  write_struct_marker(buf, fields.length())
  buf.write_byte(tag.to_byte())
  for field in fields {
    write_value(buf, field)
  }
}

///|
fn write_bytes_value(buf : Buffer, b : Bytes) -> Unit {
  write_bytes_marker(buf, b.length())
  buf.write_bytes(b.exact_view())
}

///|
/// Read a single value starting at `pos`; returns the value and the position
/// just past it, or `None` if the bytes are malformed or truncated.
fn read_value(bytes : Bytes, pos : Int) -> (PackStreamValue, Int)? {
  if pos >= bytes.length() {
    return None
  }
  let marker = bytes[pos].to_int()
  let p = pos + 1
  if marker == 0xC0 {
    Some((PackStreamValue::Null, p))
  } else if marker == 0xC2 {
    Some((PackStreamValue::Bool(false), p))
  } else if marker == 0xC3 {
    Some((PackStreamValue::Bool(true), p))
  } else if marker == 0xC1 {
    if p + 8 > bytes.length() {
      None
    } else {
      Some((PackStreamValue::Float(read_double_be(bytes, p)), p + 8))
    }
  } else if marker <= 0x7F || marker >= 0xF0 {
    Some((PackStreamValue::Int(read_tiny_int(marker)), p))
  } else if marker >= 0x80 && marker <= 0x8F {
    read_string(bytes, p, marker - 0x80)
  } else if marker >= 0x90 && marker <= 0x9F {
    read_list(bytes, p, marker - 0x90)
  } else if marker >= 0xA0 && marker <= 0xAF {
    read_map(bytes, p, marker - 0xA0)
  } else if marker >= 0xB0 && marker <= 0xBF {
    read_struct(bytes, p, marker - 0xB0)
  } else if marker == 0xC8 {
    read_int_sized(bytes, p, 1)
  } else if marker == 0xC9 {
    read_int_sized(bytes, p, 2)
  } else if marker == 0xCA {
    read_int_sized(bytes, p, 4)
  } else if marker == 0xCB {
    read_int_sized(bytes, p, 8)
  } else if marker >= 0xCC && marker <= 0xCE {
    match read_sized_header(bytes, marker, p) {
      None => None
      Some((n, data)) => read_bytes_value(bytes, data, n)
    }
  } else if marker >= 0xD0 && marker <= 0xD2 {
    match read_sized_header(bytes, marker, p) {
      None => None
      Some((n, data)) => read_string(bytes, data, n)
    }
  } else if marker >= 0xD4 && marker <= 0xD6 {
    match read_sized_header(bytes, marker, p) {
      None => None
      Some((n, data)) => read_list(bytes, data, n)
    }
  } else if marker >= 0xD8 && marker <= 0xDA {
    match read_sized_header(bytes, marker, p) {
      None => None
      Some((n, data)) => read_map(bytes, data, n)
    }
  } else if marker == 0xDC || marker == 0xDD {
    match read_sized_header(bytes, marker, p) {
      None => None
      Some((n, data)) => read_struct(bytes, data, n)
    }
  } else {
    None
  }
}

///|
/// Read the length field of a sized marker (1/2/4 bytes depending on the
/// marker), returning `(length, data_start)`.
fn read_sized_header(bytes : Bytes, marker : Int, pos : Int) -> (Int, Int)? {
  if marker == 0xCC ||
    marker == 0xD0 ||
    marker == 0xD4 ||
    marker == 0xD8 ||
    marker == 0xDC {
    match read_len8(bytes, pos) {
      None => None
      Some(n) => Some((n, pos + 1))
    }
  } else if marker == 0xCD ||
    marker == 0xD1 ||
    marker == 0xD5 ||
    marker == 0xD9 ||
    marker == 0xDD {
    match read_len16(bytes, pos) {
      None => None
      Some(n) => Some((n, pos + 2))
    }
  } else {
    match read_len32(bytes, pos) {
      None => None
      Some(n) => Some((n, pos + 4))
    }
  }
}

///|
fn read_len8(bytes : Bytes, pos : Int) -> Int? {
  if pos >= bytes.length() {
    None
  } else {
    Some(bytes[pos].to_int())
  }
}

///|
fn read_len16(bytes : Bytes, pos : Int) -> Int? {
  if pos + 2 > bytes.length() {
    None
  } else {
    Some(bytes[pos].to_int() * 256 + bytes[pos + 1].to_int())
  }
}

///|
fn read_len32(bytes : Bytes, pos : Int) -> Int? {
  if pos + 4 > bytes.length() {
    return None
  }
  let n : Int64 = (bytes[pos].to_int64() << 24)
    .lor(bytes[pos + 1].to_int64() << 16)
    .lor(bytes[pos + 2].to_int64() << 8)
    .lor(bytes[pos + 3].to_int64())
  if n > 2147483647L {
    None
  } else {
    Some(n.to_int())
  }
}

///|
/// Decode a tiny integer marker byte (`0x00..0x7F` / `0xF0..0xFF`) into an `Int64`.
fn read_tiny_int(marker : Int) -> Int64 {
  if marker >= 0xF0 {
    (marker - 256).to_int64()
  } else {
    marker.to_int64()
  }
}

///|
/// Read an `n`-byte (`n` in 1/2/4/8) big-endian signed integer, sign-extended.
fn read_int_be(bytes : Bytes, pos : Int, n : Int) -> Int64 {
  let u = read_uint_be(bytes, pos, n)
  let shift : Int = (8 - n) * 8
  (u << shift).reinterpret_as_int64() >> shift
}

///|
/// Assemble `n` bytes at `pos` into a big-endian `UInt64` (zero-padded above).
fn read_uint_be(bytes : Bytes, pos : Int, n : Int) -> UInt64 {
  let mut u : UInt64 = 0UL
  for i in 0..<n {
    u = (u << 8).lor(bytes[pos + i].to_uint64())
  }
  u
}

///|
fn read_double_be(bytes : Bytes, pos : Int) -> Double {
  read_uint_be(bytes, pos, 8).reinterpret_as_double()
}

///|
fn read_int_sized(bytes : Bytes, pos : Int, n : Int) -> (PackStreamValue, Int)? {
  if pos + n > bytes.length() {
    None
  } else {
    Some((PackStreamValue::Int(read_int_be(bytes, pos, n)), pos + n))
  }
}

///|
fn read_string(bytes : Bytes, pos : Int, n : Int) -> (PackStreamValue, Int)? {
  if n < 0 || n > bytes.length() - pos {
    None
  } else {
    let view = bytes.exact_view(start=pos, end=pos + n)
    try @utf8.decode(view) catch {
      _ => None
    } noraise {
      s => Some((PackStreamValue::Str(s), pos + n))
    }
  }
}

///|
fn read_bytes_value(
  bytes : Bytes,
  pos : Int,
  n : Int,
) -> (PackStreamValue, Int)? {
  if n < 0 || n > bytes.length() - pos {
    None
  } else {
    Some(
      (
        PackStreamValue::Bytes(
          bytes.exact_view(start=pos, end=pos + n).to_owned(),
        ),
        pos + n,
      ),
    )
  }
}

///|
fn read_list(bytes : Bytes, pos : Int, n : Int) -> (PackStreamValue, Int)? {
  if n < 0 {
    return None
  }
  let items : Array[PackStreamValue] = []
  let mut p = pos
  for _ in 0..<n {
    match read_value(bytes, p) {
      None => return None
      Some((v, np)) => {
        items.push(v)
        p = np
      }
    }
  }
  Some((PackStreamValue::List(items), p))
}

///|
fn read_map(bytes : Bytes, pos : Int, n : Int) -> (PackStreamValue, Int)? {
  if n < 0 {
    return None
  }
  let entries : Array[(String, PackStreamValue)] = []
  let mut p = pos
  for _ in 0..<n {
    match read_value(bytes, p) {
      None => return None
      Some((PackStreamValue::Str(k), p1)) =>
        match read_value(bytes, p1) {
          None => return None
          Some((v, p2)) => {
            entries.push((k, v))
            p = p2
          }
        }
      Some((_, _)) => return None
    }
  }
  Some((PackStreamValue::Map(entries), p))
}

///|
fn read_struct(bytes : Bytes, pos : Int, n : Int) -> (PackStreamValue, Int)? {
  if n < 0 || pos >= bytes.length() {
    return None
  }
  let tag = bytes[pos].to_int()
  let fields : Array[PackStreamValue] = []
  let mut p = pos + 1
  for _ in 0..<n {
    match read_value(bytes, p) {
      None => return None
      Some((v, np)) => {
        fields.push(v)
        p = np
      }
    }
  }
  Some((PackStreamValue::Struct(tag, fields), p))
}
