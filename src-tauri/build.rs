use serde::Deserialize;
use std::{env, fs, path::PathBuf};

#[derive(Deserialize)]
struct Credentials {
    client_id: String,
    client_secret: String,
}

fn main() {
    tauri_build::build();
    println!("cargo:rerun-if-changed=../credentials.json");

    let source = fs::read_to_string("../credentials.json")
        .unwrap_or_else(|_| panic!("credentials.json is missing; copy credentials.example.json and add your SoundCloud credentials"));
    let credentials: Credentials = serde_json::from_str(&source).unwrap_or_else(|_| {
        panic!("credentials.json must contain string client_id and client_secret fields")
    });

    if credentials.client_id.trim().is_empty() || credentials.client_secret.trim().is_empty() {
        panic!("credentials.json fields cannot be empty");
    }

    let generated = format!(
        "pub const CLIENT_ID: &str = {:?};\npub const CLIENT_SECRET: &str = {:?};\n",
        credentials.client_id, credentials.client_secret
    );
    let output = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR is set by Cargo"))
        .join("client_credentials.rs");
    fs::write(output, generated).expect("could not write generated credentials");
}
