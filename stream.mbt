///|
/// Streaming PackStream reader/writer used by the Bolt transport layer.
///
/// The [`packstream`] entry points work on whole `Bytes` buffers. These types
/// add an incremental interface on top of the same codec: a [`Writer`]
/// accumulates values onto a growable buffer, and a [`Reader`] reads values
/// one at a time from a cursor. The Bolt layer needs both — it assembles a
/// message with a writer, then reassembles and walks a response with a reader.

///|
/// A growable PackStream writer. Values are encoded onto an internal buffer and
/// flushed with [`Writer::to_bytes`] once a whole message has been assembled.
pub struct Writer {
  buf : Buffer
}

///|
pub fn Writer::new() -> Writer {
  { buf: Buffer::Buffer(), }
}

///|
/// Append `value` to the writer's buffer.
pub fn Writer::write(self : Writer, value : PackStreamValue) -> Unit {
  write_value(self.buf, value)
}

///|
/// Flush the accumulated bytes.
pub fn Writer::to_bytes(self : Writer) -> Bytes {
  self.buf.to_bytes()
}

///|
/// A PackStream reader over a byte buffer with a cursor.
pub struct Reader {
  bytes : Bytes
  mut pos : Int
}

///|
pub fn Reader::new(bytes : Bytes) -> Reader {
  { bytes, pos: 0, }
}

///|
/// Read the next value at the cursor, advancing past it. Returns `None` on
/// malformed or truncated input (the cursor is left unchanged in that case).
pub fn Reader::read(self : Reader) -> PackStreamValue? {
  match read_value(self.bytes, self.pos) {
    None => None
    Some((value, next)) => {
      self.pos = next
      Some(value)
    }
  }
}

///|
/// Whether the reader has consumed all of its input.
pub fn Reader::eof(self : Reader) -> Bool {
  self.pos >= self.bytes.length()
}

///|
/// Number of bytes left to consume.
pub fn Reader::remaining(self : Reader) -> Int {
  self.bytes.length() - self.pos
}
