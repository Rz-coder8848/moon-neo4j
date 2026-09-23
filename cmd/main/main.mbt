///|
/// Entry point for the `moon-neo4j` demo CLI.
///
/// Run with `moon run cmd/main` from the project root.
///
/// With no arguments it runs the full movie-graph demo (query the actors of
/// *The Matrix*, then add a person inside an explicit transaction). Pass
/// `add <name>` to run only the "add a person" demo with a custom name.
fn main {
  let args = @env.args()
  if args.length() > 0 && args[0] == "add" {
    let name = if args.length() > 1 { args[1] } else { "Lilly Wachowski" }
    @lib.demo_add_person(name, 1967L)
  } else {
    @lib.demo_actors("The Matrix")
    @lib.demo_add_person("Lilly Wachowski", 1967L)
  }
}
