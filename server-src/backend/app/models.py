from __future__ import annotations
from pydantic import BaseModel
from typing import Optional


class ChatRequest(BaseModel):
    message: str


class ConversationCreate(BaseModel):
    provider_id: str = "openai"
    model: str = "gpt-4o"
    title: str = "New Chat"


class ConversationUpdate(BaseModel):
    title: Optional[str] = None
    provider_id: Optional[str] = None
    model: Optional[str] = None
    agent_mode: Optional[str] = None
    system_prompt: Optional[str] = None


class SettingsUpdate(BaseModel):
    settings: dict[str, str]


class PushSubscribe(BaseModel):
    endpoint: str
    keys: dict[str, str]


class PushUnsubscribe(BaseModel):
    endpoint: str


class ChaoxingLogin(BaseModel):
    phone: str


class ChaoxingVerify(BaseModel):
    phone: str
    code: str


class CustomProviderCreate(BaseModel):
    id: str
    name: str
    api_type: str = "openAICompatible"
    base_url: str
    api_key: str = ""
    models: list[str] = []
