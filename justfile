# bufo search justfile
mod bot

# re-index all bufos with new embeddings
re-index:
    @echo "re-indexing all bufos with input_type=document..."
    uv run scripts/ingest_bufos.py

# deploy to fly.io
deploy:
    @echo "deploying to fly.io..."
    fly deploy --wait-timeout 180

# run dev server with hot reload
dev:
    @echo "starting dev server with hot reload..."
    RUST_LOG=info cargo watch -x run -w src -w static

# build and run locally
run:
    @echo "building and running locally..."
    cargo build --release
    ./target/release/find-bufo

# build release binary
build:
    @echo "building release binary..."
    cargo build --release
