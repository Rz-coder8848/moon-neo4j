///|
/// A typed Cypher query builder.
///
/// Hand-writing a Cypher string and inlining runtime values invites Cypher
/// injection. Instead, build the query clause-by-clause and bind every runtime
/// value through [`Query::param`]. `param` stores the value in the query's
/// parameter list and returns a generated `$pN` reference, so values travel to
/// the server out-of-band — like a prepared statement.
///
/// ```moonbit
/// let q = Query::new()
/// let name = q.param(PackStreamValue::str("Alice")) // -> "$p0"
/// q.match_("(p:Person)")
/// q.where_("p.name = " + name)
/// q.return_("p.name, p.age")
/// let (cypher, params) = q.build()
/// // cypher == "MATCH (p:Person) WHERE p.name = $p0 RETURN p.name, p.age"
/// // params == [("p0", PackStreamValue::str("Alice"))]
/// ```
///
/// [`Query::build`] returns a `(cypher, parameters)` pair that feeds directly
/// into [`BoltConnection::run_query`] or `http::Statement::new`.

///|
/// An in-progress Cypher query. The clauses are accumulated in order; the
/// parameters are collected as `(name, value)` pairs keyed by the bare name
/// (the `$` reference in the query text resolves to this key on the server).
pub struct Query {
  clauses : Array[String]
  params : Array[(String, PackStreamValue)]
  mut counter : Int
}

///|
/// Start a new, empty query.
pub fn Query::new() -> Query {
  { clauses: [], params: [], counter: 0, }
}

///|
/// Bind a runtime value and return its generated `$pN` reference. The value is
/// stored in the query's parameter list under the bare name (without `$`), so
/// it is sent out-of-band and cannot be interpreted as Cypher syntax.
pub fn Query::param(self : Query, value : PackStreamValue) -> String {
  let id = self.counter.to_string()
  self.counter = self.counter + 1
  self.params.push(("p" + id, value))
  "$p" + id
}

///|
/// Append `MATCH <pattern>`.
pub fn Query::match_(self : Query, pattern : String) -> Unit {
  add_clause(self, "MATCH", pattern)
}

///|
/// Append `OPTIONAL MATCH <pattern>`.
pub fn Query::optional_match(self : Query, pattern : String) -> Unit {
  add_clause(self, "OPTIONAL MATCH", pattern)
}

///|
/// Append `WHERE <predicate>`.
pub fn Query::where_(self : Query, predicate : String) -> Unit {
  add_clause(self, "WHERE", predicate)
}

///|
/// Append `WITH <projection>`.
pub fn Query::with_(self : Query, projection : String) -> Unit {
  add_clause(self, "WITH", projection)
}

///|
/// Append `CREATE <pattern>`.
pub fn Query::create(self : Query, pattern : String) -> Unit {
  add_clause(self, "CREATE", pattern)
}

///|
/// Append `MERGE <pattern>`.
pub fn Query::merge(self : Query, pattern : String) -> Unit {
  add_clause(self, "MERGE", pattern)
}

///|
/// Append `SET <assignments>`.
pub fn Query::set(self : Query, assignments : String) -> Unit {
  add_clause(self, "SET", assignments)
}

///|
/// Append `DELETE <expression>`.
pub fn Query::delete(self : Query, expression : String) -> Unit {
  add_clause(self, "DELETE", expression)
}

///|
/// Append `DETACH DELETE <expression>`.
pub fn Query::detach_delete(self : Query, expression : String) -> Unit {
  add_clause(self, "DETACH DELETE", expression)
}

///|
/// Append `RETURN <expression>`.
pub fn Query::return_(self : Query, expression : String) -> Unit {
  add_clause(self, "RETURN", expression)
}

///|
/// Append `ORDER BY <expression>` (ascending). Use [`Query::order_by_desc`] for
/// descending order.
pub fn Query::order_by(self : Query, expression : String) -> Unit {
  add_clause(self, "ORDER BY", expression)
}

///|
/// Append `ORDER BY <expression> DESC`.
pub fn Query::order_by_desc(self : Query, expression : String) -> Unit {
  add_clause(self, "ORDER BY", expression + " DESC")
}

///|
/// Append `SKIP <n>`.
pub fn Query::skip(self : Query, n : Int) -> Unit {
  add_clause(self, "SKIP", n.to_string())
}

///|
/// Append `LIMIT <n>`.
pub fn Query::limit(self : Query, n : Int) -> Unit {
  add_clause(self, "LIMIT", n.to_string())
}

///|
/// Finalize the query into its `(cypher, parameters)` pair, ready for
/// [`BoltConnection::run_query`] or `http::Statement::new`.
pub fn Query::build(self : Query) -> (String, Array[(String, PackStreamValue)]) {
  (self.clauses.join(" "), self.params)
}

///|
/// Append a `keyword + body` clause to the query's clause list.
fn add_clause(q : Query, keyword : String, body : String) -> Unit {
  q.clauses.push(keyword + " " + body)
}
