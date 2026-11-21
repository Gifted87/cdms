extern crate tree_sitter_elixir;
extern crate tree_sitter_javascript;
extern crate tree_sitter_python;
extern crate tree_sitter_java;
extern crate tree_sitter_typescript;
extern crate tree_sitter_c_sharp;
extern crate tree_sitter_cpp;
extern crate tree_sitter_php;
extern crate tree_sitter_go;
extern crate tree_sitter_rust;

use rustler::{Atom, Encoder, Env, NifResult, Term};
use std::sync::{Arc, RwLock};
use std::collections::HashMap;
use tree_sitter::{Language, Parser, Node};
use crate::ast_node::AstNode;

/// Registry for language grammars.
pub struct ParserManager {
    grammars: Arc<RwLock<HashMap<String, Language>>>,
}

impl ParserManager {
    pub fn new() -> Self {
        let mut grammars = HashMap::new();
        // Register supported grammars (Elixir initialized by example)
        // Note: Actual .so loading would happen here or in a pre-init hook.
        // For this implementation, we assume static linking or pre-loaded grammars.
        grammars.insert("elixir".to_string(), tree_sitter_elixir::LANGUAGE.into());
        grammars.insert("javascript".to_string(), tree_sitter_javascript::LANGUAGE.into());
        grammars.insert("python".to_string(), tree_sitter_python::LANGUAGE.into());
        grammars.insert("java".to_string(), tree_sitter_java::LANGUAGE.into());
        grammars.insert("typescript".to_string(), tree_sitter_typescript::LANGUAGE_TYPESCRIPT.into());
        grammars.insert("csharp".to_string(), tree_sitter_c_sharp::LANGUAGE.into());
        grammars.insert("cpp".to_string(), tree_sitter_cpp::LANGUAGE.into());
        grammars.insert("php".to_string(), tree_sitter_php::LANGUAGE_PHP.into());
        grammars.insert("go".to_string(), tree_sitter_go::LANGUAGE.into());
        grammars.insert("rust".to_string(), tree_sitter_rust::LANGUAGE.into());
        
        Self {
            grammars: Arc::new(RwLock::new(grammars)),
        }
    }

    pub fn get_language(&self, lang: &str) -> Option<Language> {
        self.grammars.read().ok()?.get(lang).cloned()
    }
}

/// Entry point for parsing source code via NIF.
#[rustler::nif]
pub fn parse_source(env: Env, lang_atom: Atom, source_code: String) -> NifResult<Term> {
    let lang_name = lang_atom.to_term(env).atom_to_string().unwrap();
    
    // 1. Resolve language grammar
    let language = match get_global_parser_manager().get_language(&lang_name) {
        Some(l) => l,
        None => return Ok((rustler::Atom::from_str(env, "error").unwrap(), "language_not_supported").encode(env)),
    };

    // 2. Perform parsing in a scoped thread to protect BEAM scheduler
    let result = std::panic::catch_unwind(|| -> Result<AstNode, &str> {
        let mut parser = Parser::new();
        parser.set_language(&language).map_err(|_| "grammar_load_error")?;
        
        let tree = parser.parse(&source_code, None).ok_or("parsing_failed")?;
        let root = tree.root_node();
        
        Ok(walk_node(root, &source_code, &lang_name))
    });

    match result {
        Ok(Ok(ast)) => Ok(ast.encode(env)),
        Ok(Err(e)) => Ok((rustler::Atom::from_str(env, "error").unwrap(), e).encode(env)),
        Err(_) => Ok((rustler::Atom::from_str(env, "error").unwrap(), "parser_panic").encode(env)),
    }
}

/// Recursively walks the tree-sitter node structure.
fn walk_node(node: Node, source: &str, file_path: &str) -> AstNode {
    let mut children = Vec::new();
    let mut cursor = node.walk();
    
    for child in node.children(&mut cursor) {
        children.push(walk_node(child, source, file_path));
    }

    let start = node.start_position();
    let end = node.end_position();

    AstNode {
        node_type: node.kind().to_string(),
        content: node.utf8_text(source.as_bytes()).unwrap_or("").to_string(),
        file_path: file_path.to_string(),
        start_line: start.row + 1,
        start_col: start.column + 1,
        end_line: end.row + 1,
        end_col: end.column + 1,
        children,
    }
}

/// Global instance of the parser manager.
fn get_global_parser_manager() -> &'static ParserManager {
    use std::sync::OnceLock;
    static MANAGER: OnceLock<ParserManager> = OnceLock::new();
    MANAGER.get_or_init(ParserManager::new)
}
