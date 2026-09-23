///|
/// Whitebox tests for the PackStream codec: fixed wire-format vectors (taken
/// from the Neo4j Bolt PackStream specification) plus encode/decode round-trips.

///|
fn assert_encodes(value : PackStreamValue, expected : Bytes) -> Unit raise {
  assert_eq(packstream_encode(value), expected)
}

///|
fn round_trip(value : PackStreamValue) -> Unit raise {
  assert_eq(packstream_decode(packstream_encode(value)), Some(value))
}

///|
/// Null and booleans.
test {
  assert_encodes(PackStreamValue::null(), b"\xc0")
  assert_encodes(PackStreamValue::bool(false), b"\xc2")
  assert_encodes(PackStreamValue::bool(true), b"\xc3")
}

///|
/// Integers: tiny, INT_8, INT_16, INT_32 and INT_64 markers.
test {
  // Tiny integers (-16..127) are a single signed byte.
  assert_encodes(PackStreamValue::int(0L), b"\x00")
  assert_encodes(PackStreamValue::int(127L), b"\x7f")
  assert_encodes(PackStreamValue::int(-1L), b"\xff")
  assert_encodes(PackStreamValue::int(-16L), b"\xf0")
  // INT_8.
  assert_encodes(PackStreamValue::int(-17L), b"\xc8\xef")
  assert_encodes(PackStreamValue::int(-128L), b"\xc8\x80")
  // INT_16.
  assert_encodes(PackStreamValue::int(128L), b"\xc9\x00\x80")
  assert_encodes(PackStreamValue::int(-129L), b"\xc9\xff\x7f")
  assert_encodes(PackStreamValue::int(32767L), b"\xc9\x7f\xff")
  assert_encodes(PackStreamValue::int(-32768L), b"\xc9\x80\x00")
  // INT_32.
  assert_encodes(PackStreamValue::int(32768L), b"\xca\x00\x00\x80\x00")
  assert_encodes(PackStreamValue::int(-32769L), b"\xca\xff\xff\x7f\xff")
  // INT_64.
  assert_encodes(
    PackStreamValue::int(2147483648L),
    b"\xcb\x00\x00\x00\x00\x80\x00\x00\x00",
  )
}

///|
/// Float64.
test {
  assert_encodes(
    PackStreamValue::float(1.0),
    b"\xc1\x3f\xf0\x00\x00\x00\x00\x00\x00",
  )
}

///|
/// Strings: tiny and 8-bit-length forms, including a multi-byte UTF-8 string.
test {
  assert_encodes(PackStreamValue::str(""), b"\x80")
  assert_encodes(PackStreamValue::str("hello"), b"\x85hello")
  // 16 bytes trips the STRING_8 marker (0xD0) with an 8-bit length.
  assert_encodes(
    PackStreamValue::str("1234567890123456"),
    b"\xd0\x101234567890123456",
  )
  // "héllo" is 6 UTF-8 bytes (é = 0xC3 0xA9).
  assert_encodes(PackStreamValue::str("héllo"), b"\x86h\xc3\xa9llo")
}

///|
/// Lists.
test {
  assert_encodes(PackStreamValue::list([]), b"\x90")
  assert_encodes(
    PackStreamValue::list([
      PackStreamValue::int(1L),
      PackStreamValue::int(2L),
      PackStreamValue::int(3L),
    ]),
    b"\x93\x01\x02\x03",
  )
}

///|
/// Maps (string -> value).
test {
  assert_encodes(PackStreamValue::map([]), b"\xa0")
  assert_encodes(
    PackStreamValue::map([("name", PackStreamValue::str("Alice"))]),
    b"\xa1\x84name\x85Alice",
  )
}

///|
/// Structs (tag byte + fields).
test {
  assert_encodes(PackStreamValue::struct_(1, []), b"\xb0\x01")
  assert_encodes(
    PackStreamValue::struct_(1, [PackStreamValue::int(1L)]),
    b"\xb1\x01\x01",
  )
}

///|
/// Bytes.
test {
  assert_encodes(PackStreamValue::bytes(b""), b"\xcc\x00")
  assert_encodes(
    PackStreamValue::bytes(b"\x01\x02\x03"),
    b"\xcc\x03\x01\x02\x03",
  )
}

///|
/// Round-trip across a nested value and several scalar kinds.
test {
  round_trip(PackStreamValue::null())
  round_trip(PackStreamValue::bool(true))
  round_trip(PackStreamValue::int(-123456789012345L))
  round_trip(PackStreamValue::float(-2.5))
  round_trip(PackStreamValue::str("héllo, 世界"))
  round_trip(
    PackStreamValue::map([
      (
        "user",
        PackStreamValue::struct_(0x01, [
          PackStreamValue::str("Alice"),
          PackStreamValue::int(42L),
          PackStreamValue::list([
            PackStreamValue::bool(false),
            PackStreamValue::null(),
          ]),
        ]),
      ),
    ]),
  )
  round_trip(PackStreamValue::bytes(b"\x00\xff\x10\x00"))
}

///|
/// Decoder rejects malformed or incomplete input.
test {
  assert_eq(packstream_decode(b""), None)
  // Truncated string (claims 5 bytes, only 2 present).
  assert_eq(packstream_decode(b"\x85he"), None)
  // Truncated float (marker + 7 of 8 bytes).
  assert_eq(packstream_decode(b"\xc1\x3f\xf0\x00\x00\x00\x00\x00"), None)
  // Reserved marker 0xC4.
  assert_eq(packstream_decode(b"\xc4"), None)
  // Trailing garbage after a complete value.
  assert_eq(packstream_decode(b"\xc0\xc0"), None)
  // Truncated INT_64 (marker + 3 of 8 bytes).
  assert_eq(packstream_decode(b"\xcb\x00\x00\x00"), None)
  // Map with a non-string key.
  assert_eq(packstream_decode(b"\xa1\x01\x02"), None)
}

///|
/// The first marker byte of `value`'s encoding.
fn marker_of(value : PackStreamValue) -> Byte {
  packstream_encode(value)[0]
}

///|
/// A list of `n` integer values `0, 1, 2, ...`.
fn int_list(n : Int) -> Array[PackStreamValue] {
  Array::makei(n, fn(i) { PackStreamValue::int(i.to_int64()) })
}

///|
/// A map of `n` entries `("k0", 0)`, `("k1", 1)`, ...
fn str_map(n : Int) -> Array[(String, PackStreamValue)] {
  Array::makei(n, fn(i) { ("k\{i}", PackStreamValue::int(i.to_int64())) })
}

///|
/// Integer marker-size boundaries (tiny / INT_8 / INT_16 / INT_32 / INT_64).
test {
  assert_eq(marker_of(PackStreamValue::int(127L)), b'\x7f')
  assert_eq(marker_of(PackStreamValue::int(128L)), b'\xc9')
  assert_eq(marker_of(PackStreamValue::int(-16L)), b'\xf0')
  assert_eq(marker_of(PackStreamValue::int(-17L)), b'\xc8')
  assert_eq(marker_of(PackStreamValue::int(-128L)), b'\xc8')
  assert_eq(marker_of(PackStreamValue::int(-129L)), b'\xc9')
  assert_eq(marker_of(PackStreamValue::int(32767L)), b'\xc9')
  assert_eq(marker_of(PackStreamValue::int(32768L)), b'\xca')
  assert_eq(marker_of(PackStreamValue::int(-32768L)), b'\xc9')
  assert_eq(marker_of(PackStreamValue::int(-32769L)), b'\xca')
  assert_eq(marker_of(PackStreamValue::int(2147483647L)), b'\xca')
  assert_eq(marker_of(PackStreamValue::int(2147483648L)), b'\xcb')
  assert_eq(marker_of(PackStreamValue::int(-2147483648L)), b'\xca')
  assert_eq(marker_of(PackStreamValue::int(-2147483649L)), b'\xcb')
  round_trip(PackStreamValue::int(9223372036854775807L))
  round_trip(PackStreamValue::int(-9223372036854775808L))
}

///|
/// String length-marker boundaries (tiny / STRING_8 / STRING_16 / STRING_32).
test {
  assert_eq(marker_of(PackStreamValue::str(String::make(15, 'a'))), b'\x8f')
  assert_eq(marker_of(PackStreamValue::str(String::make(16, 'a'))), b'\xd0')
  assert_eq(marker_of(PackStreamValue::str(String::make(255, 'a'))), b'\xd0')
  assert_eq(marker_of(PackStreamValue::str(String::make(256, 'a'))), b'\xd1')
  assert_eq(marker_of(PackStreamValue::str(String::make(65535, 'a'))), b'\xd1')
  assert_eq(marker_of(PackStreamValue::str(String::make(65536, 'a'))), b'\xd2')
  round_trip(PackStreamValue::str(String::make(16, 'a')))
  round_trip(PackStreamValue::str(String::make(256, 'a')))
  round_trip(PackStreamValue::str(String::make(65536, 'a')))
}

///|
/// List length-marker boundaries (tiny / LIST_8 / LIST_16 / LIST_32).
test {
  assert_eq(marker_of(PackStreamValue::list(int_list(15))), b'\x9f')
  assert_eq(marker_of(PackStreamValue::list(int_list(16))), b'\xd4')
  assert_eq(marker_of(PackStreamValue::list(int_list(256))), b'\xd5')
  assert_eq(marker_of(PackStreamValue::list(int_list(65536))), b'\xd6')
  round_trip(PackStreamValue::list(int_list(16)))
  round_trip(PackStreamValue::list(int_list(256)))
}

///|
/// Map length-marker boundaries (tiny / MAP_8 / MAP_16).
test {
  assert_eq(marker_of(PackStreamValue::map(str_map(15))), b'\xaf')
  assert_eq(marker_of(PackStreamValue::map(str_map(16))), b'\xd8')
  assert_eq(marker_of(PackStreamValue::map(str_map(256))), b'\xd9')
  round_trip(PackStreamValue::map(str_map(16)))
}

///|
/// Struct length-marker boundaries (tiny / STRUCT_8 / STRUCT_16).
test {
  assert_eq(marker_of(PackStreamValue::struct_(1, int_list(15))), b'\xbf')
  assert_eq(marker_of(PackStreamValue::struct_(1, int_list(16))), b'\xdc')
  assert_eq(marker_of(PackStreamValue::struct_(1, int_list(256))), b'\xdd')
  round_trip(PackStreamValue::struct_(1, int_list(16)))
}

///|
/// Bytes length-marker boundaries (BYTES_8 / BYTES_16 / BYTES_32; no tiny form).
test {
  assert_eq(marker_of(PackStreamValue::bytes(b"a".repeat(255))), b'\xcc')
  assert_eq(marker_of(PackStreamValue::bytes(b"a".repeat(256))), b'\xcd')
  assert_eq(marker_of(PackStreamValue::bytes(b"a".repeat(65535))), b'\xcd')
  assert_eq(marker_of(PackStreamValue::bytes(b"a".repeat(65536))), b'\xce')
  round_trip(PackStreamValue::bytes(b"a".repeat(256)))
}

///|
/// Decode vectors for the sized (non-tiny) markers.
test {
  assert_eq(
    packstream_decode(b"\xd0\x05hello"),
    Some(PackStreamValue::str("hello")),
  )
  assert_eq(
    packstream_decode(b"\xd1\x00\x05hello"),
    Some(PackStreamValue::str("hello")),
  )
  assert_eq(
    packstream_decode(b"\xd4\x02\x01\x02"),
    Some(
      PackStreamValue::list([PackStreamValue::int(1L), PackStreamValue::int(2L)]),
    ),
  )
  assert_eq(
    packstream_decode(b"\xd8\x01\x81a\x01"),
    Some(PackStreamValue::map([("a", PackStreamValue::int(1L))])),
  )
  assert_eq(
    packstream_decode(b"\xdc\x01\x01\x01"),
    Some(PackStreamValue::struct_(1, [PackStreamValue::int(1L)])),
  )
  assert_eq(
    packstream_decode(b"\xcc\x02\x01\x02"),
    Some(PackStreamValue::bytes(b"\x01\x02")),
  )
  assert_eq(
    packstream_decode(b"\xcd\x00\x02\x01\x02"),
    Some(PackStreamValue::bytes(b"\x01\x02")),
  )
}
