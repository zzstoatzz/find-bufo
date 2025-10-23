# find-bufo

semantic search for the bufo zone

**live at: [find-bufo.fly.dev](https://find-bufo.fly.dev/)**

## overview

a one-page application for searching through all the bufos from [bufo.zone](https://bufo.zone/) using multi-modal embeddings and vector search.

## architecture

- **backend**: rust (actix-web)
- **frontend**: vanilla html/css/js
- **embeddings**: voyage ai voyage-multimodal-3
- **vector store**: turbopuffer
- **deployment**: fly.io

## setup

1. install dependencies:
   - rust toolchain
   - python 3.11+ with uv

2. copy environment variables:
   ```bash
   cp .env.example .env
   ```

3. set your api keys in `.env`:
   - `VOYAGE_API_TOKEN` - for generating embeddings
   - `TURBOPUFFER_API_KEY` - for vector storage

## ingestion

to populate the vector store with bufos:

```bash
just re-index
```

this will:
1. scrape all bufos from bufo.zone
2. download them to `data/bufos/`
3. generate embeddings for each image with `input_type="document"`
4. upload to turbopuffer

## development

run the server locally:

```bash
cargo run
```

the app will be available at `http://localhost:8080`

## deployment

deploy to fly.io:

```bash
fly launch  # first time
fly secrets set VOYAGE_API_TOKEN=your_token
fly secrets set TURBOPUFFER_API_KEY=your_key
just deploy
```

## usage

1. open the app
2. enter a search query describing the bufo you want
3. see the top matching bufos with similarity scores
4. click any bufo to open it in a new tab

## how it works

1. **ingestion**: all bufo images are embedded using voyage ai's multimodal-3 model with `input_type="document"` for optimized retrieval
2. **search**: user queries are embedded with the same model using `input_type="query"` to align query and document embeddings
3. **retrieval**: turbopuffer finds the most similar bufos using cosine distance
4. **display**: results are shown with similarity scores
