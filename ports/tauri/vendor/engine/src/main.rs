//! `scanstudio-engine` binary entry point.

fn main() {
    let mut args = std::env::args();
    let _program = args.next();

    if let Some(arg) = args.next() {
        if arg == "--version" {
            println!("scanstudio-engine {}", env!("CARGO_PKG_VERSION"));
            return;
        }
    }

    scanstudio_engine::server::run();
}
