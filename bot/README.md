# bufo-bot

bluesky bot that listens to the firehose and quote-posts matching bufo images.

## how it works

1. connects to bluesky jetstream (firehose)
2. for each post, checks if text contains an exact phrase matching a bufo name
3. if matched, quote-posts with the corresponding bufo image

## matching logic

- extracts phrase from bufo filename (e.g., `bufo-hop-in-we-re-going` -> `hop in we re going`)
- requires exact consecutive word match in post text
- configurable minimum phrase length (default: 4 words)

## configuration

| env var | default | description |
|---------|---------|-------------|
| `BSKY_HANDLE` | required | bluesky handle (e.g., `find-bufo.com`) |
| `BSKY_APP_PASSWORD` | required | app password from bsky settings |
| `MIN_PHRASE_WORDS` | `4` | minimum words in phrase to match |
| `POSTING_ENABLED` | `false` | must be `true` to actually post |
| `COOLDOWN_MINUTES` | `120` | don't repost same bufo within this time |
| `JETSTREAM_ENDPOINT` | `jetstream2.us-east.bsky.network` | jetstream server |

## local dev

```bash
# copy and edit .env
cp .env.example .env

# run locally (dry run by default)
uv run bufo-bot

# or test matching against firehose
uv run python -m bufo_bot.dry_run
```

## deploy

```bash
# set secrets (once)
fly secrets set BSKY_HANDLE=find-bufo.com BSKY_APP_PASSWORD=xxxx -a bufo-bot

# deploy
fly deploy

# enable posting
fly secrets set POSTING_ENABLED=true -a bufo-bot

# disable posting
fly secrets set POSTING_ENABLED=false -a bufo-bot

# check logs
fly logs -a bufo-bot
```
