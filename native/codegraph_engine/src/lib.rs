mod parser;
mod ast_node;

rustler::init!("Elixir.CMS.Ingestion.CodeGraph.Native", [
    parser::parse_source
]);
