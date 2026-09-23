///|
/// Whitebox tests for the typed Cypher query builder.

///|
/// An empty query builds to an empty cypher string and no parameters.
test {
  let q = Query::new()
  let (cypher, params) = q.build()
  assert_eq(cypher, "")
  assert_eq(params, [])
}

///|
/// `param` returns sequential `$pN` references and stores the bare names.
test {
  let q = Query::new()
  assert_eq(q.param(PackStreamValue::str("Alice")), "$p0")
  assert_eq(q.param(PackStreamValue::int(42L)), "$p1")
  assert_eq(q.param(PackStreamValue::bool(true)), "$p2")
  let (cypher, params) = q.build()
  assert_eq(cypher, "")
  assert_eq(params, [
    ("p0", PackStreamValue::str("Alice")),
    ("p1", PackStreamValue::int(42L)),
    ("p2", PackStreamValue::bool(true)),
  ])
}

///|
/// Clauses accumulate in order, separated by single spaces.
test {
  let q = Query::new()
  q.match_("(p:Person)")
  q.where_("p.age > 21")
  q.return_("p.name")
  let (cypher, params) = q.build()
  assert_eq(cypher, "MATCH (p:Person) WHERE p.age > 21 RETURN p.name")
  assert_eq(params, [])
}

///|
/// A full write query uses CREATE/SET/RETURN and a bound parameter.
test {
  let q = Query::new()
  let name = q.param(PackStreamValue::str("Alice"))
  q.create("(p:Person {name: " + name + "})")
  q.set("p.age = 30")
  q.return_("p")
  let (cypher, params) = q.build()
  assert_eq(cypher, "CREATE (p:Person {name: $p0}) SET p.age = 30 RETURN p")
  assert_eq(params, [("p0", PackStreamValue::str("Alice"))])
}

///|
/// MERGE, DETACH DELETE and ORDER BY are emitted verbatim.
test {
  let q = Query::new()
  q.merge("(p:Person {id: 1})")
  q.order_by_desc("p.age")
  q.limit(10)
  q.skip(5)
  q.detach_delete("p")
  let (cypher, params) = q.build()
  assert_eq(
    cypher, "MERGE (p:Person {id: 1}) ORDER BY p.age DESC LIMIT 10 SKIP 5 DETACH DELETE p",
  )
  assert_eq(params, [])
}

///|
/// OPTIONAL MATCH, WITH and DELETE are emitted verbatim.
test {
  let q = Query::new()
  q.optional_match("(p:Person)-[:KNOWS]->(f:Person)")
  q.with_("p, collect(f) AS friends")
  q.delete("p")
  let (cypher, params) = q.build()
  assert_eq(
    cypher, "OPTIONAL MATCH (p:Person)-[:KNOWS]->(f:Person) WITH p, collect(f) AS friends DELETE p",
  )
  assert_eq(params, [])
}

///|
/// `order_by` emits ascending by default, `order_by_desc` appends DESC.
test {
  let q1 = Query::new()
  q1.order_by("p.name")
  assert_eq(q1.build().0, "ORDER BY p.name")

  let q2 = Query::new()
  q2.order_by_desc("p.name")
  assert_eq(q2.build().0, "ORDER BY p.name DESC")
}

///|
/// The built `(cypher, parameters)` pair round-trips through the Bolt RUN codec.
test {
  let q = Query::new()
  let name = q.param(PackStreamValue::str("Bob"))
  q.match_("(p:Person)")
  q.where_("p.name = " + name)
  q.return_("p.name")
  let (cypher, params) = q.build()

  // The RUN message accepts the exact same query + parameters pair.
  let run_msg = run(cypher, params, [])
  assert_eq(
    run_msg,
    PackStreamValue::struct_(SIG_RUN, [
      PackStreamValue::str("MATCH (p:Person) WHERE p.name = $p0 RETURN p.name"),
      PackStreamValue::map([("p0", PackStreamValue::str("Bob"))]),
      PackStreamValue::map([]),
    ]),
  )
}
