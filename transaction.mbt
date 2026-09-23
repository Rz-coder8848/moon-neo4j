///|
/// A Bolt explicit transaction: BEGIN, run one or more statements, then COMMIT
/// or ROLLBACK.
///
/// An explicit transaction groups several statements so they commit or roll
/// back atomically. In auto-commit mode each statement commits on its own; an
/// explicit transaction defers the write until [`Transaction::commit`].
///
/// ```moonbit
/// let conn = BoltConnection::new(transport) // ... after handshake + HELLO
/// let tx = Transaction::new(conn)
/// assert_eq(tx.begin(), true)
/// let _ = tx.run("CREATE (n:Person {name: \$name})", [("name", ...)])
/// assert_eq(tx.commit(), true)
/// ```
///
/// The transaction tracks an `open` flag and refuses out-of-order calls: `run`
/// before `begin`, or a second `begin`/`commit`/`rollback`, return `false`/`None`
/// instead of corrupting the wire. A statement that the server rejects leaves
/// the connection in the `Failed` state; recover it with
/// [`BoltConnection::reset_conn`] (a failed transaction is rolled back by the
/// server and must be reset, per the Bolt protocol).

///|
/// An explicit Bolt transaction bound to a [`BoltConnection`].
pub struct Transaction[T] {
  conn : BoltConnection[T]
  mut open : Bool
}

///|
/// Wrap a connection in a (not yet started) transaction. The connection must
/// already be handshaken and authenticated (in the [`Ready`](ConnState::Ready)
/// state).
pub fn[T] Transaction::new(conn : BoltConnection[T]) -> Transaction[T] {
  { conn, open: false, }
}

///|
/// Begin the transaction with `BEGIN`. Returns `true` when the server accepted
/// it, `false` otherwise (already open, wrong connection state, or a server
/// failure).
pub fn[T : Transport] Transaction::begin(self : Transaction[T]) -> Bool {
  if self.open {
    return false
  }
  match self.conn.begin_tx([]) {
    Some(ServerMessage::Success(_)) => {
      self.open = true
      true
    }
    _ => false
  }
}

///|
/// Run a statement inside the transaction and pull every record, returning the
/// rows. Returns `None` when the transaction is not open, the connection is not
/// ready, or the server rejected the statement.
pub fn[T : Transport] Transaction::run(
  self : Transaction[T],
  query : String,
  parameters : Array[(String, PackStreamValue)],
) -> Array[Array[PackStreamValue]]? {
  if !self.open {
    return None
  }
  self.conn.run_query(query, parameters)
}

///|
/// Commit the transaction with `COMMIT`. Returns `true` on success; the
/// transaction is then closed either way.
pub fn[T : Transport] Transaction::commit(self : Transaction[T]) -> Bool {
  if !self.open {
    return false
  }
  self.open = false
  match self.conn.commit_tx() {
    Some(ServerMessage::Success(_)) => true
    _ => false
  }
}

///|
/// Roll the transaction back with `ROLLBACK`. Returns `true` on success; the
/// transaction is then closed either way.
pub fn[T : Transport] Transaction::rollback(self : Transaction[T]) -> Bool {
  if !self.open {
    return false
  }
  self.open = false
  match self.conn.rollback_tx() {
    Some(ServerMessage::Success(_)) => true
    _ => false
  }
}

///|
/// Whether the transaction is currently open.
pub fn[T] Transaction::is_open(self : Transaction[T]) -> Bool {
  self.open
}
