///|
/// A runnable "movie graph" demo — the classic *The Matrix* graph — that
/// exercises the whole stack end to end.
///
/// MoonBit's core library ships no socket, so there is no real network behind
/// this demo (需查官方文档 for the platform's socket API). Instead, the demo
/// drives a [`MockTransport`] that plays back a scripted server's replies — a
/// stand-in for a Neo4j instance that already contains the movie graph. The
/// Cypher is built by the typed [`Query`] builder, serialized over the Bolt
/// wire, and the decoded rows are printed with the value's [`Show`] instance.
///
/// Everything here is real except the bytes on the far side of the transport.

///|
/// Build the "who acted in this movie" query.
pub fn actors_query(
  title : String,
) -> (String, Array[(String, PackStreamValue)]) {
  let q = Query::new()
  let t = q.param(PackStreamValue::str(title))
  q.match_("(p:Person)-[:ACTED_IN]->(m:Movie)")
  q.where_("m.title = " + t)
  q.return_("p.name")
  q.order_by("p.name")
  q.build()
}

///|
/// Build the "add a person" query.
pub fn add_person_query(
  name : String,
  born : Int64,
) -> (String, Array[(String, PackStreamValue)]) {
  let q = Query::new()
  let n = q.param(PackStreamValue::str(name))
  let b = q.param(PackStreamValue::int(born))
  q.create("(p:Person {name: " + n + ", born: " + b + "})")
  q.return_("p.name")
  q.build()
}

///|
/// A scripted server whose replies answer the [`actors_query`] demo: it returns
/// the three actors of *The Matrix*.
pub fn scripted_actors_server() -> MockTransport {
  let mock = MockTransport::new()
  mock.feed(b"\x00\x00\x01\x05") // handshake
  mock.feed(demo_success([])) // HELLO
  mock.feed(
    demo_success([
      ("fields", PackStreamValue::list([PackStreamValue::str("p.name")])),
    ]),
  ) // RUN
  mock.feed(demo_record([PackStreamValue::str("Carrie-Anne Moss")]))
  mock.feed(demo_record([PackStreamValue::str("Keanu Reeves")]))
  mock.feed(demo_record([PackStreamValue::str("Laurence Fishburne")]))
  mock.feed(demo_success([])) // PULL done
  mock
}

///|
/// A scripted server whose replies answer the [`add_person_query`] demo run
/// inside an explicit transaction.
pub fn scripted_add_server(name : String) -> MockTransport {
  let mock = MockTransport::new()
  mock.feed(b"\x00\x00\x01\x05") // handshake
  mock.feed(demo_success([])) // HELLO
  mock.feed(demo_success([])) // BEGIN
  mock.feed(
    demo_success([
      ("fields", PackStreamValue::list([PackStreamValue::str("p.name")])),
    ]),
  ) // RUN
  mock.feed(demo_record([PackStreamValue::str(name)])) // PULL record
  mock.feed(demo_success([])) // PULL done
  mock.feed(demo_success([])) // COMMIT
  mock
}

///|
/// Run the "actors in a movie" demo and print the result.
pub fn demo_actors(title : String) -> Unit {
  let (cypher, params) = actors_query(title)
  let mock = scripted_actors_server()
  let conn = BoltConnection::new(mock)
  let _ = conn.handshake([bolt_version(5, 1, 0)])
  let _ = conn.authenticate([
    ("user_agent", PackStreamValue::str("moon-neo4j/0.1")),
  ])
  println("Cypher: " + cypher)
  match conn.run_query(cypher, params) {
    None => println("(query failed)")
    Some(records) => {
      println("Actors in \"" + title + "\":")
      for record in records {
        println("  - " + format_record(record))
      }
    }
  }
}

///|
/// Run the "add a person" demo (inside an explicit transaction) and print the
/// result.
pub fn demo_add_person(name : String, born : Int64) -> Unit {
  let (cypher, params) = add_person_query(name, born)
  let mock = scripted_add_server(name)
  let conn = BoltConnection::new(mock)
  let _ = conn.handshake([bolt_version(5, 1, 0)])
  let _ = conn.authenticate([
    ("user_agent", PackStreamValue::str("moon-neo4j/0.1")),
  ])
  let tx = Transaction::new(conn)
  println("Cypher: " + cypher)
  if tx.begin() {
    match tx.run(cypher, params) {
      Some(_) =>
        if tx.commit() {
          println(
            "Added \"" +
            name +
            "\" (born " +
            born.to_string() +
            ") in a transaction.",
          )
        } else {
          println("(commit failed)")
        }
      None => println("(statement failed)")
    }
  } else {
    println("(begin failed)")
  }
}

///|
/// Join a record's fields with `, `, using each value's [`Show`] rendering.
fn format_record(record : Array[PackStreamValue]) -> String {
  let parts = []
  for field in record {
    parts.push(field.to_string())
  }
  parts.join(", ")
}

///|
/// A framed server SUCCESS carrying `metadata`.
fn demo_success(metadata : Array[(String, PackStreamValue)]) -> Bytes {
  frame(PackStreamValue::struct_(SIG_SUCCESS, [PackStreamValue::map(metadata)]))
}

///|
/// A framed server RECORD carrying `fields`.
fn demo_record(fields : Array[PackStreamValue]) -> Bytes {
  frame(PackStreamValue::struct_(SIG_RECORD, [PackStreamValue::list(fields)]))
}
