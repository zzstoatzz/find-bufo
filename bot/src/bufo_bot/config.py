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

    model_config = {"env_file": ".env", "extra": "ignore"}


settings = Settings()
