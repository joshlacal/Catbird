fn main() {
    // UniFFI 0.28+ generates metadata automatically from macros
    // No manual scaffolding needed - the setup_scaffolding! macro handles it
    println!("cargo:rerun-if-changed=src/");
}

