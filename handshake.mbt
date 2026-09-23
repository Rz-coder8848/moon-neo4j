///|
/// Bolt protocol handshake: the magic preamble and version negotiation.
///
/// A Bolt connection begins with a fixed 20-byte handshake: the 4-byte magic
/// [`MAGIC`], then four 4-byte version proposals in big-endian order. The
/// server replies with a single 4-byte agreed version, or `0x00000000` when no
/// proposed version is supported.
///
/// A version is a 32-bit value laid out `[0x00 reserved][range][minor][major]`
/// (big-endian); `range` is how many consecutive minor versions below `minor`
/// are also accepted. See https://neo4j.com/docs/bolt/current/bolt/handshake/.

///|
/// The 4-byte magic preamble sent at the start of every Bolt connection.
pub const MAGIC : Bytes = b"\x60\x60\xb0\x17"

///|
/// Encode a Bolt version `(major, minor, range)` into its 4-byte wire value.
///
/// `range` is the number of consecutive minor versions *below* `minor` that are
/// also accepted (0 = only the single `major.minor`).
pub fn bolt_version(major : Int, minor : Int, range : Int) -> Int {
  major | (minor << 8) | (range << 16)
}

///|
/// Build the 20-byte handshake message: [`MAGIC`] followed by four version
/// proposals, padded with `0x00000000` when fewer than four are given.
///
/// Versions are sent in priority order; the server picks the first it supports.
pub fn handshake_message(versions : Array[Int]) -> Bytes {
  let buf = Buffer::Buffer()
  buf.write_bytes(MAGIC.exact_view())
  for i in 0..<4 {
    let v = if i < versions.length() { versions[i] } else { 0 }
    buf.write_int_be(v)
  }
  buf.to_bytes()
}

///|
/// Parse the server's 4-byte handshake response into an agreed version.
///
/// Returns `None` when the response is not exactly 4 bytes, or when the server
/// selected `0x00000000` ("no supported version").
pub fn parse_handshake_response(bytes : Bytes) -> Int? {
  if bytes.length() != 4 {
    None
  } else {
    let v = read_uint_be(bytes, 0, 4).to_int()
    if v == 0 {
      None
    } else {
      Some(v)
    }
  }
}
