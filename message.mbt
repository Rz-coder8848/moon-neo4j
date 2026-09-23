///|
/// Bolt message codec: the message signatures, typed client-message builders, a
/// typed server-message parser, and the chunked wire framing.
///
/// Every Bolt message is a PackStream struct whose single-byte tag (the struct
/// signature) identifies the message type. Messages are sent in "chunks": each
/// chunk is prefixed with a big-endian 16-bit length, and a `0x0000` chunk
/// terminates the message. See https://neo4j.com/docs/bolt/current/bolt/message/.

// ---------------------------------------------------------------------------
// Message signatures.
// ---------------------------------------------------------------------------

///|
/// Client signature: HELLO.
pub const SIG_HELLO : Int = 0x01

///|
/// Client signature: GOODBYE.
pub const SIG_GOODBYE : Int = 0x02

///|
/// Client signature: RESET.
pub const SIG_RESET : Int = 0x0F

///|
/// Client signature: RUN.
pub const SIG_RUN : Int = 0x10

///|
/// Client signature: BEGIN.
pub const SIG_BEGIN : Int = 0x11

///|
/// Client signature: COMMIT.
pub const SIG_COMMIT : Int = 0x12

///|
/// Client signature: ROLLBACK.
pub const SIG_ROLLBACK : Int = 0x13

///|
/// Client signature: DISCARD.
pub const SIG_DISCARD : Int = 0x2F

///|
/// Client signature: PULL.
pub const SIG_PULL : Int = 0x3F

///|
/// Server signature: SUCCESS.
pub const SIG_SUCCESS : Int = 0x70

///|
/// Server signature: RECORD.
pub const SIG_RECORD : Int = 0x71

///|
/// Server signature: IGNORED.
pub const SIG_IGNORED : Int = 0x7E

///|
/// Server signature: FAILURE.
pub const SIG_FAILURE : Int = 0x7F

// ---------------------------------------------------------------------------
// Client messages.
// ---------------------------------------------------------------------------

///|
/// HELLO: initiate a session with connection metadata (user agent, auth, ...).
pub fn hello(metadata : Array[(String, PackStreamValue)]) -> PackStreamValue {
  PackStreamValue::struct_(SIG_HELLO, [PackStreamValue::map(metadata)])
}

///|
/// GOODBYE: gracefully close the connection.
pub fn goodbye() -> PackStreamValue {
  PackStreamValue::struct_(SIG_GOODBYE, [])
}

///|
/// RESET: return the connection to a clean state, discarding any open transaction.
pub fn reset() -> PackStreamValue {
  PackStreamValue::struct_(SIG_RESET, [])
}

///|
/// RUN: start a query/transaction. `extra` carries mode, bookmarks and
/// transaction metadata.
pub fn run(
  query : String,
  parameters : Array[(String, PackStreamValue)],
  extra : Array[(String, PackStreamValue)],
) -> PackStreamValue {
  PackStreamValue::struct_(SIG_RUN, [
    PackStreamValue::str(query),
    PackStreamValue::map(parameters),
    PackStreamValue::map(extra),
  ])
}

///|
/// BEGIN: start an explicit transaction.
pub fn begin(extra : Array[(String, PackStreamValue)]) -> PackStreamValue {
  PackStreamValue::struct_(SIG_BEGIN, [PackStreamValue::map(extra)])
}

///|
/// COMMIT: commit the open transaction.
pub fn commit() -> PackStreamValue {
  PackStreamValue::struct_(SIG_COMMIT, [])
}

///|
/// ROLLBACK: roll back the open transaction.
pub fn rollback() -> PackStreamValue {
  PackStreamValue::struct_(SIG_ROLLBACK, [])
}

///|
/// DISCARD: discard the remaining records of a result.
pub fn discard(extra : Array[(String, PackStreamValue)]) -> PackStreamValue {
  PackStreamValue::struct_(SIG_DISCARD, [PackStreamValue::map(extra)])
}

///|
/// PULL: request the next records of a result.
pub fn pull(extra : Array[(String, PackStreamValue)]) -> PackStreamValue {
  PackStreamValue::struct_(SIG_PULL, [PackStreamValue::map(extra)])
}

// ---------------------------------------------------------------------------
// Server messages.
// ---------------------------------------------------------------------------

///|
/// A message sent by the server in response to client messages.
pub enum ServerMessage {
  Success(Array[(String, PackStreamValue)])
  Record(Array[PackStreamValue])
  Failure(Array[(String, PackStreamValue)])
  Ignored
} derive(Eq, @debug.Debug)

///|
/// Parse a PackStream struct into a [`ServerMessage`], or `None` when the tag
/// is unknown or the fields do not match the message's shape.
pub fn parse_message(value : PackStreamValue) -> ServerMessage? {
  match value {
    Struct(tag, fields) => parse_server(tag, fields)
    _ => None
  }
}

///|
fn parse_server(tag : Int, fields : Array[PackStreamValue]) -> ServerMessage? {
  if tag == SIG_SUCCESS {
    match fields {
      [Map(m)] => Some(ServerMessage::Success(m))
      _ => None
    }
  } else if tag == SIG_RECORD {
    match fields {
      [List(record)] => Some(ServerMessage::Record(record))
      _ => None
    }
  } else if tag == SIG_FAILURE {
    match fields {
      [Map(m)] => Some(ServerMessage::Failure(m))
      _ => None
    }
  } else if tag == SIG_IGNORED {
    if fields.length() == 0 {
      Some(ServerMessage::Ignored)
    } else {
      None
    }
  } else {
    None
  }
}

// ---------------------------------------------------------------------------
// Chunked framing.
// ---------------------------------------------------------------------------

///|
/// Frame a message struct into Bolt's chunked wire encoding: the PackStream
/// payload split into ≤65535-byte chunks, each prefixed by a big-endian 16-bit
/// length, terminated by a `0x0000` chunk.
pub fn frame(value : PackStreamValue) -> Bytes {
  let payload = packstream_encode(value)
  let buf = Buffer::Buffer()
  let mut i = 0
  let n = payload.length()
  while i < n {
    let chunk = if n - i > 65535 { 65535 } else { n - i }
    write_chunk_len(buf, chunk)
    buf.write_bytes(payload.exact_view(start=i, end=i + chunk))
    i = i + chunk
  }
  write_chunk_len(buf, 0)
  buf.to_bytes()
}

///|
/// Reassemble a chunked message into its PackStream payload bytes. Returns
/// `None` on a truncated chunk or a missing `0x0000` terminator.
pub fn unframe(bytes : Bytes) -> Bytes? {
  let buf = Buffer::Buffer()
  let mut pos = 0
  let n = bytes.length()
  while pos + 2 <= n {
    let chunk = bytes[pos].to_int() * 256 + bytes[pos + 1].to_int()
    pos = pos + 2
    if chunk == 0 {
      return Some(buf.to_bytes())
    }
    if pos + chunk > n {
      return None
    }
    buf.write_bytes(bytes.exact_view(start=pos, end=pos + chunk))
    pos = pos + chunk
  }
  None
}

///|
/// Write a 16-bit big-endian length.
fn write_chunk_len(buf : Buffer, len : Int) -> Unit {
  buf.write_byte((len >> 8).to_byte())
  buf.write_byte((len & 0xFF).to_byte())
}
