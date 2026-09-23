///|
/// The Bolt transport abstraction: a byte pipe between the client and the
/// server. The Bolt protocol above this layer — the handshake and the chunked
/// message framing — is built entirely on [`Transport`], so a state machine can
/// be driven over any concrete transport (a TCP socket in production, or the
/// in-memory [`MockTransport`] in tests).
///
/// The three methods mirror what a blocking socket provides: `write` sends
/// bytes, `read_exact` reads exactly `n` bytes (returning `None` on EOF before
/// `n` bytes arrive), and `close` tears the connection down.

///|
/// A raw, byte-oriented transport for Bolt.
pub trait Transport {
  ///| Send `bytes` to the peer.
  fn write(Self, Bytes) -> Unit
  ///| Read exactly `n` bytes, or `None` if the connection closes first.
  fn read_exact(Self, Int) -> Bytes?
  ///| Close the connection.
  fn close(Self) -> Unit
}

///|
/// An in-memory [`Transport`] used to test the protocol layer without a
/// network. Tests pre-load the server's reply with [`MockTransport::feed`] and
/// inspect what the client sent with [`MockTransport::outgoing`].
pub struct MockTransport {
  inbound : Buffer
  mut inpos : Int
  outbound : Buffer
  mut closed : Bool
}

///|
pub fn MockTransport::new() -> MockTransport {
  {
    inbound: Buffer::Buffer(),
    inpos: 0,
    outbound: Buffer::Buffer(),
    closed: false,
  }
}

///|
/// Append bytes the "server" will later send to the client.
pub fn MockTransport::feed(self : MockTransport, bytes : Bytes) -> Unit {
  self.inbound.write_bytes(bytes.exact_view())
}

///|
/// The bytes the client has written so far.
pub fn MockTransport::outgoing(self : MockTransport) -> Bytes {
  self.outbound.to_bytes()
}

///|
/// Whether [`MockTransport::close`] has been called.
pub fn MockTransport::is_closed(self : MockTransport) -> Bool {
  self.closed
}

///|
pub impl Transport for MockTransport with fn write(self, bytes) {
  self.outbound.write_bytes(bytes.exact_view())
}

///|
pub impl Transport for MockTransport with fn read_exact(self, n) {
  let all = self.inbound.to_bytes()
  if self.inpos + n > all.length() {
    None
  } else {
    let chunk = all.exact_view(start=self.inpos, end=self.inpos + n).to_owned()
    self.inpos = self.inpos + n
    Some(chunk)
  }
}

///|
pub impl Transport for MockTransport with fn close(self) {
  self.closed = true
}

///|
/// Re-export the transport methods as regular methods on [`MockTransport`].
pub extend MockTransport with Transport::{write, read_exact, close}
