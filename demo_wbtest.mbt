///|
/// Whitebox tests for the movie demo: the generated Cypher and the scripted
/// server round-trip.

///|
/// `actors_query` emits the expected parameterized Cypher.
test {
  let (cypher, params) = actors_query("The Matrix")
  assert_eq(
    cypher, "MATCH (p:Person)-[:ACTED_IN]->(m:Movie) WHERE m.title = $p0 RETURN p.name ORDER BY p.name",
  )
  assert_eq(params, [("p0", PackStreamValue::str("The Matrix"))])
}

///|
/// `add_person_query` binds both parameters out-of-band.
test {
  let (cypher, params) = add_person_query("Lana Wachowski", 1965L)
  assert_eq(cypher, "CREATE (p:Person {name: $p0, born: $p1}) RETURN p.name")
  assert_eq(params, [
    ("p0", PackStreamValue::str("Lana Wachowski")),
    ("p1", PackStreamValue::int(1965L)),
  ])
}

///|
/// The scripted server round-trips the actors query end to end.
test {
  let (cypher, params) = actors_query("The Matrix")
  let mock = scripted_actors_server()
  let conn = BoltConnection::new(mock)
  let _ = conn.handshake([bolt_version(5, 1, 0)])
  let _ = conn.authenticate([
    ("user_agent", PackStreamValue::str("moon-neo4j/0.1")),
  ])
  match conn.run_query(cypher, params) {
    Some(records) =>
      assert_eq(records, [
        [PackStreamValue::str("Carrie-Anne Moss")],
        [PackStreamValue::str("Keanu Reeves")],
        [PackStreamValue::str("Laurence Fishburne")],
      ])
    None => panic()
  }
}

///|
/// The `Show` rendering is used by the demo to print values.
test {
  assert_eq(PackStreamValue::null().to_string(), "null")
  assert_eq(PackStreamValue::bool(true).to_string(), "true")
  assert_eq(PackStreamValue::int(42L).to_string(), "42")
  assert_eq(PackStreamValue::str("Alice").to_string(), "Alice")
  assert_eq(
    PackStreamValue::list([PackStreamValue::int(1L), PackStreamValue::str("a")]).to_string(),
    "[1, a]",
  )
  assert_eq(
    PackStreamValue::map([("k", PackStreamValue::str("v"))]).to_string(),
    "{k: v}",
  )
}
