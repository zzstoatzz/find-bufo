# find-bufo

hybrid semantic + keyword search for the bufo zone

**live at: [find-bufo.fly.dev](https://find-bufo.fly.dev/)**

## overview

a one-page application for searching through all the bufos from [bufo.zone](https://bufo.zone/) using hybrid search that combines:
- **semantic search** via multimodal embeddings (understands meaning and visual content)
- **keyword search** via BM25 full-text search (finds exact filename matches)

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
3. see the top matching bufos with hybrid similarity scores
4. click any bufo to open it in a new tab

### api parameters

the search API supports these parameters:
- `query`: search text (required)
- `top_k`: number of results (default: 10)
- `alpha`: fusion weight (default: 0.7)
  - `1.0` = pure semantic (best for conceptual queries like "happy", "apocalyptic")
  - `0.7` = default (balances semantic understanding with exact matches)
  - `0.5` = balanced (equal weight to both signals)
  - `0.0` = pure keyword (best for exact filename searches)

example: `/api/search?query=jumping&top_k=5&alpha=0.5`

## how it works

### ingestion
all bufo images are processed through early fusion multimodal embeddings:
1. filename text extracted (e.g., "bufo-jumping-on-bed" → "bufo jumping on bed")
2. combined with image content in single embedding request
3. voyage-multimodal-3 creates 1024-dim vectors capturing both text and visual features
4. uploaded to turbopuffer with BM25-enabled `name` field for keyword search

### search
1. **semantic branch**: query embedded using voyage-multimodal-3 with `input_type="query"`
2. **keyword branch**: BM25 full-text search against bufo names
3. **fusion**: weighted combination using `alpha` parameter
   - `score = α * semantic + (1-α) * keyword`
   - both scores normalized to 0-1 range before fusion
4. **ranking**: results sorted by fused score, top_k returned

### why hybrid?
- semantic alone: misses exact filename matches (e.g., "happy" might not find "bufo-is-happy")
- keyword alone: no semantic understanding (e.g., "happy" won't find "excited" or "smiling")
- hybrid: gets the best of both worlds
