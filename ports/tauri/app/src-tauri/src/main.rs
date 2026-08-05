#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod wsl;

fn main() {
    scanstudio_app_lib::run();
}
