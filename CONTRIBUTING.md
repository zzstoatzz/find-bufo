# contributing to find-bufo

## what is a bufo?

bufos are frog images from [bufo.zone](https://all-the.bufo.zone). find-bufo is a bluesky bot that watches the firehose and quote-posts with a matching bufo image when someone's post contains a bufo phrase.

## submitting a new bufo

### naming

the filename **is** the matching phrase. `bufo-jumping-for-joy.png` matches posts containing "jumping for joy".

- use kebab-case: `bufo-descriptive-phrase.png`
- `.png` or `.gif` only
- keep it descriptive — the phrase should make sense as a natural match

### how to submit

1. fork the repo on [tangled.org](https://tangled.org/zzstoatzz.io/find-bufo)
2. add your image to `data/bufos/`
3. open a PR with a screenshot or preview of the bufo in action

### what happens next

a maintainer runs the ingestion script (`scripts/add_one_bufo.py`) to embed and index your image. once merged and deployed, the bot starts matching posts with your bufo's phrase.
