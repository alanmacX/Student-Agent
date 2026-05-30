from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    openai_api_key: str = ""
    anthropic_api_key: str = ""
    gemini_api_key: str = ""
    mimo_api_key: str = ""

    vapid_private_key: str = ""
    vapid_public_key: str = ""
    vapid_mailto: str = "mailto:admin@example.com"

    database_path: str = "/data/chatbot.db"
    chaoxing_sync_interval: int = 300
    chaoxing_memory_interval: int = 1800

    debug: bool = False
    standby_interval_minutes: int = 15
    standby_agent_provider: str = "openai"
    standby_agent_model: str = "gpt-4o-mini"

    class Config:
        env_file = ".env"


settings = Settings()
