///|
/// A Bolt session: the connection state machine that drives the protocol over
/// a [`Transport`].
///
/// The state machine walks the Bolt lifecycle:
///
/// ```text
/// Disconnected --handshake--> Connected --hello--> Ready
///     Ready --run--> Streaming --pull (records)--> Ready
///     any     --failure--> Failed   --reset--> Ready
///     any     --close--> Closed
/// ```
///
/// Every method enforces the transition's precondition and returns `None` when
/// the session is not in the required state, so an invalid call sequence fails
/// loudly instead of corrupting the wire protocol.

///|
/// The lifecycle state of a Bolt session.
pub enum ConnState {
  Disconnected
  Connected
  Ready
  Streaming
  Failed
  Closed
} derive(Eq, @debug.Debug)

///|
/// A Bolt session over a concrete transport.
pub struct BoltConnection[T] {
  transport : T
  mut state : ConnState
}

///|
pub fn[T] BoltConnection::new(transport : T) -> BoltConnection[T] {
  { transport, state: Disconnected, }
}

///|
/// The session's current [`ConnState`].
pub fn[T] BoltConnection::conn_state(self : BoltConnection[T]) -> ConnState {
  self.state
}

///|
/// Perform the Bolt handshake, proposing `versions` in priority order.
///
/// Returns the version the server agreed on, or `None` when the server rejected
/// every proposal or the connection dropped. On success the session moves to
/// [`Connected`](ConnState::Connected); on failure to [`Failed`](ConnState::Failed).
pub fn[T : Transport] BoltConnection::handshake(
  self : BoltConnection[T],
  versions : Array[Int],
) -> Int? {
  if self.state != Disconnected {
    return None
  }
  self.transport.write(handshake_message(versions))
  match self.transport.read_exact(4) {
    None => {
      self.state = Failed
      None
    }
    Some(response) =>
      match parse_handshake_response(response) {
        None => {
          self.state = Failed
          None
        }
        Some(version) => {
          self.state = Connected
          Some(version)
        }
      }
  }
}

///|
/// Send HELLO to authenticate the session. `metadata` carries the user agent
/// and auth token (see the higher-level driver for how to build it).
///
/// Returns the server's response: [`Success`](ServerMessage::Success) (session
/// becomes [`Ready`](ConnState::Ready)), or [`Failure`](ServerMessage::Failure)
/// (session becomes [`Failed`](ConnState::Failed)). Returns `None` on an
/// unexpected response or a dropped connection.
pub fn[T : Transport] BoltConnection::authenticate(
  self : BoltConnection[T],
  metadata : Array[(String, PackStreamValue)],
) -> ServerMessage? {
  if self.state != Connected {
    return None
  }
  self.transport.write(frame(hello(metadata)))
  match read_server(self.transport) {
    None => {
      self.state = Failed
      None
    }
    Some(msg) =>
      match msg {
        ServerMessage::Success(_) => {
          self.state = Ready
          Some(msg)
        }
        ServerMessage::Failure(_) => {
          self.state = Failed
          Some(msg)
        }
        _ => None
      }
  }
}

///|
/// Send RUN to begin evaluating a query. The session must be [`Ready`](ConnState::Ready);
/// on a server [`Success`](ServerMessage::Success) it becomes [`Streaming`](ConnState::Streaming).
pub fn[T : Transport] BoltConnection::start_run(
  self : BoltConnection[T],
  query : String,
  parameters : Array[(String, PackStreamValue)],
  extra : Array[(String, PackStreamValue)],
) -> ServerMessage? {
  if self.state != Ready {
    return None
  }
  self.transport.write(frame(run(query, parameters, extra)))
  match read_server(self.transport) {
    None => {
      self.state = Failed
      None
    }
    Some(msg) =>
      match msg {
        ServerMessage::Success(_) => {
          self.state = Streaming
          Some(msg)
        }
        ServerMessage::Failure(_) => {
          self.state = Failed
          Some(msg)
        }
        _ => None
      }
  }
}

///|
/// Send PULL and read the next server message: a [`Record`](ServerMessage::Record),
/// the stream's final [`Success`](ServerMessage::Success) (session returns to
/// [`Ready`](ConnState::Ready)), or a [`Failure`](ServerMessage::Failure).
pub fn[T : Transport] BoltConnection::pull_next(
  self : BoltConnection[T],
  extra : Array[(String, PackStreamValue)],
) -> ServerMessage? {
  if self.state != Streaming {
    return None
  }
  self.transport.write(frame(pull(extra)))
  match read_server(self.transport) {
    None => {
      self.state = Failed
      None
    }
    Some(msg) =>
      match msg {
        ServerMessage::Success(_) => {
          self.state = Ready
          Some(msg)
        }
        ServerMessage::Failure(_) => {
          self.state = Failed
          Some(msg)
        }
        ServerMessage::Record(_) => Some(msg)
        ServerMessage::Ignored => Some(msg)
      }
  }
}

///|
/// Reset the session after a failure, returning it to [`Ready`](ConnState::Ready).
pub fn[T : Transport] BoltConnection::reset_conn(
  self : BoltConnection[T],
) -> ServerMessage? {
  if self.state == Closed || self.state == Disconnected {
    return None
  }
  self.transport.write(frame(reset()))
  match read_server(self.transport) {
    None => {
      self.state = Failed
      None
    }
    Some(msg) =>
      match msg {
        ServerMessage::Success(_) => {
          self.state = Ready
          Some(msg)
        }
        ServerMessage::Failure(_) => {
          self.state = Failed
          Some(msg)
        }
        _ => None
      }
  }
}

///|
/// Gracefully close the session: send GOODBYE (unless already failed or
/// disconnected) and close the transport.
pub fn[T : Transport] BoltConnection::close(self : BoltConnection[T]) -> Unit {
  if self.state == Closed {
    return
  }
  if self.state == Ready || self.state == Streaming || self.state == Connected {
    self.transport.write(frame(goodbye()))
  }
  self.transport.close()
  self.state = Closed
}

///|
/// Convenience: run a query from the [`Ready`](ConnState::Ready) state and pull
/// every record, returning the rows (`Array` of field lists). The session is
/// left [`Ready`](ConnState::Ready) on success.
pub fn[T : Transport] BoltConnection::run_query(
  self : BoltConnection[T],
  query : String,
  parameters : Array[(String, PackStreamValue)],
) -> Array[Array[PackStreamValue]]? {
  match self.start_run(query, parameters, []) {
    Some(ServerMessage::Success(_)) => ()
    _ => return None
  }
  self.transport.write(frame(pull([("n", PackStreamValue::int(-1L))])))
  let records = []
  while true {
    match read_server(self.transport) {
      None => {
        self.state = Failed
        return None
      }
      Some(ServerMessage::Record(fields)) => records.push(fields)
      Some(ServerMessage::Success(_)) => {
        self.state = Ready
        return Some(records)
      }
      Some(ServerMessage::Failure(_)) => {
        self.state = Failed
        return None
      }
      Some(ServerMessage::Ignored) => ()
    }
  } nobreak {
    None
  }
}

///|
/// Read and reassemble a single chunked server message from `t`.
fn[T : Transport] read_server(t : T) -> ServerMessage? {
  let payload = Buffer::Buffer()
  while true {
    match t.read_exact(2) {
      None => return None
      Some(header) => {
        let len = header[0].to_int() * 256 + header[1].to_int()
        if len == 0 {
          match packstream_decode(payload.to_bytes()) {
            Some(value) => return parse_message(value)
            None => return None
          }
        }
        match t.read_exact(len) {
          None => return None
          Some(chunk) => payload.write_bytes(chunk.exact_view())
        }
      }
    }
  } nobreak {
    None
  }
}
