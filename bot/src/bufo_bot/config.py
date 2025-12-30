from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    bsky_handle: str
    bsky_app_password: str
    jetstream_endpoint: str = "jetstream2.us-east.bsky.network"

    # minimum words in bufo phrase to consider for matching
    min_phrase_words: int = 4

    # must be explicitly enabled to post
    posting_enabled: bool = False

    # cooldown: don't repost same bufo within this many minutes
    cooldown_minutes: int = 120

    # exclude bufos matching these patterns (comma-separated regex)
    exclude_patterns: str = "what-have-you-done,what-have-i-done,sad,crying,cant-take"

    # probability of quoting the matched post (0.0-1.0)
    # when not quoting, posts bufo with rkey reference instead
    quote_chance: float = 0.5

    model_config = {"env_file": ".env", "extra": "ignore"}


settings = Settings()
