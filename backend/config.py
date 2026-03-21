from pydantic_settings import BaseSettings, SettingsConfigDict
from typing import List


class Settings(BaseSettings):
    # Application
    PROJECT_NAME: str = "Water Disease Monitoring API"
    VERSION: str = "1.0.0"
    DEBUG: bool = False

    # API
    API_V1_STR: str = "/api/v1"

    # CORS
    ALLOWED_HOSTS: List[str] = ["*"]

    # Firebase (Firestore only)
    FIREBASE_SERVICE_ACCOUNT_PATH: str = ""
    FIREBASE_PROJECT_ID: str = ""
    FCM_ENABLED: bool = True

    # JWT Auth
    SECRET_KEY: str = "change-this-secret-key"
    ALGORITHM: str = "HS256"
    ACCESS_TOKEN_EXPIRE_DAYS: int = 7  # Long expiry — no more 30-min headaches

    # ML
    MODEL_PATH: str = "models/"
    RISK_THRESHOLD_LOW: float = 0.3
    RISK_THRESHOLD_HIGH: float = 0.7

    # Supported languages (Northeast India)
    SUPPORTED_LANGUAGES: List[str] = ["en", "hi", "as", "bn", "mni"]

    model_config = SettingsConfigDict(
        env_file=".env",
        case_sensitive=True
    )


settings = Settings()