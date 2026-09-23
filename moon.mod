// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html
//
// To add a dependency, run this command in your terminal:
//   moon add moonbitlang/x
//
// Or manually declare it in `import`, for example:
// import {
//   "moonbitlang/x@0.4.6",
// }

name = "Rz-coder8848/moon-neo4j"

version = "0.1.0"

readme = "README.md"

repository = "https://github.com/Rz-coder8848/moon-neo4j"

license = "Apache-2.0"

keywords = [
  "neo4j",
  "graph-database",
  "property-graph",
  "knowledge-graph",
  "bolt",
  "cypher",
  "client",
  "query-builder",
]

preferred_target = "wasm"

description = "A pure-MoonBit Neo4j client: Bolt protocol, PackStream codec, HTTP transactional endpoint, and a typed Cypher query builder."
