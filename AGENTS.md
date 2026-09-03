# Authoritative technical source

- SoundCloud OpenAPI spec: ./api.yaml

# General project guidelines

1. Send all SoundCloud API and SoundCloud CDN requests through the Rust client and expose them to React with Tauri commands.
2. Do not add frontend client-side tests unless explicitly asked.
