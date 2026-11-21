use rustler::{Encoder, Env, Term};

/// Maximum tree depth to prevent resource exhaustion/stack overflow.
const MAX_AST_DEPTH: usize = 128;

/// AST Node representation for Rust -> Elixir NIF boundary.
/// Captures code topography including grammatical constructs,
/// source locations, and hierarchical node relationships.
#[derive(Debug, Clone)]
pub struct AstNode {
    pub node_type: String,
    pub content: String,
    pub file_path: String,
    pub start_line: usize,
    pub start_col: usize,
    pub end_line: usize,
    pub end_col: usize,
    pub children: Vec<AstNode>,
}

impl Encoder for AstNode {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        self.encode_recursive(env, 0)
    }
}

impl AstNode {
    /// Recursively encodes the AST structure into an Elixir map.
    /// Includes depth limiting for security against pathological inputs.
    fn encode_recursive<'a>(&self, env: Env<'a>, depth: usize) -> Term<'a> {
        use rustler::types::map::map_new;

        if depth > MAX_AST_DEPTH {
            return env.error_tuple(rustler::Atom::from_str(env, "depth_limit_exceeded").unwrap());
        }

        let mut map = map_new(env);

        // Standard metadata
        map = map.map_put(
            rustler::Atom::from_str(env, "node_type").unwrap().encode(env),
            self.node_type.encode(env),
        ).unwrap();

        map = map.map_put(
            rustler::Atom::from_str(env, "content").unwrap().encode(env),
            self.content.encode(env),
        ).unwrap();

        map = map.map_put(
            rustler::Atom::from_str(env, "file_path").unwrap().encode(env),
            self.file_path.encode(env),
        ).unwrap();

        // Source range encoded as a structured map for Elixir
        let mut range = map_new(env);
        range = range.map_put("start_line".encode(env), self.start_line.encode(env)).unwrap();
        range = range.map_put("start_col".encode(env), self.start_col.encode(env)).unwrap();
        range = range.map_put("end_line".encode(env), self.end_line.encode(env)).unwrap();
        range = range.map_put("end_col".encode(env), self.end_col.encode(env)).unwrap();

        map = map.map_put(rustler::Atom::from_str(env, "source_range").unwrap().encode(env), range).unwrap();

        // Recursively encode children
        let children_list: Vec<Term> = self.children
            .iter()
            .map(|child| child.encode_recursive(env, depth + 1))
            .collect();

        map = map.map_put(
            rustler::Atom::from_str(env, "children").unwrap().encode(env),
            children_list.encode(env),
        ).unwrap();

        map
    }
}
