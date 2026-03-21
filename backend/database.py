import firebase_admin
from firebase_admin import credentials, firestore
from pydantic import BaseModel, EmailStr
from typing import Optional, List
from datetime import datetime
import logging

from config import settings

logger = logging.getLogger(__name__)


# ───────────────────────────────────────────
# FIREBASE INIT
# ───────────────────────────────────────────

def init_firebase():
    if not firebase_admin._apps:
        cred = credentials.Certificate(settings.FIREBASE_SERVICE_ACCOUNT_PATH)
        firebase_admin.initialize_app(cred, {"projectId": settings.FIREBASE_PROJECT_ID})
        logger.info("Firebase initialized")


# ───────────────────────────────────────────
# COLLECTIONS
# ───────────────────────────────────────────

class Col:
    USERS             = "users"
    WATER_QUALITY     = "water_quality"
    HEALTH_DATA       = "health_data"
    ALERTS            = "alerts"
    DETECTION_HISTORY = "detection_history"


# ───────────────────────────────────────────
# SCHEMAS
# ───────────────────────────────────────────

# --- User ---
class UserSchema(BaseModel):
    uid: str
    email: str
    full_name: str
    phone_number: str
    role: str                           # asha | health_worker | admin
    state: str
    district: str
    block: Optional[str] = None
    village: Optional[str] = None
    preferred_language: str = "en"
    created_at: str                     # ISO string


# --- Person (one row in a health submission) ---
class PersonSchema(BaseModel):
    sex: str                            # male | female | other
    age: int
    sanitation: str                     # poor | good
    water_source: str                   # source type they use
    diarrhea: int = 0                   # 0 | 1 | 2 (severity)
    fatigue: int = 0
    vomiting: int = 0
    fever: int = 0
    jaundice: int = 0
    headache: int = 0
    loss_of_appetite: int = 0
    muscle_aches: int = 0


# --- Water Source Input (one entry in the water_sources list) ---
class WaterSourceInput(BaseModel):
    name: str
    source_type: str
    ph: Optional[float] = None
    turbidity: Optional[float] = None
    temperature: Optional[float] = None
    rainfall: Optional[float] = None
    dissolved_oxygen: Optional[float] = None
    chlorine: Optional[float] = None
    fecal_coliform: Optional[float] = None
    hardness: Optional[float] = None
    nitrate: Optional[float] = None
    tds: Optional[float] = None
    season: Optional[str] = None       # Winter | Summer | Monsoon | Autumn
    month: Optional[int] = None        # 1–12


# --- Water Source Result (stored after ML prediction) ---
class WaterSourceResult(BaseModel):
    source_name: str
    source_type: str
    risk_score: float                   # 0.0 – 1.0
    risk_level: str                     # low | medium | high
    risk_percent: float                 # 0 – 100


# --- Health Submission (what ASHA worker submits) ---
class HealthSubmission(BaseModel):
    house_id: str                       # household identifier
    persons: List[PersonSchema]         # list of people surveyed
    water_sources: List[WaterSourceInput]  # multiple water sources
    state: Optional[str] = None
    district: Optional[str] = None
    block: Optional[str] = None
    village: Optional[str] = None


# --- Detection Record (stored in Firestore after pipeline run) ---
class DetectionRecord(BaseModel):
    id: str
    submitted_by: str                   # user uid
    house_id: str                       # household identifier
    state: Optional[str] = None
    district: Optional[str] = None
    block: Optional[str] = None
    village: Optional[str] = None
    total_persons: int
    persons_with_symptoms: int
    health_predictions: List[dict]      # per-person true_prob + at_risk
    water_sources: List[dict]           # list of WaterSourceResult dicts
    # top-level fields for backward compat / quick queries
    water_source_name: str              # name of highest-risk source
    water_risk_level: str               # highest risk level across sources
    water_risk_percent: float           # highest risk percent across sources
    alert_triggered: bool = False
    submitted_at: str                   # ISO string


# --- Alert ---
class AlertSchema(BaseModel):
    id: str
    type: str                           # water_contamination | disease_outbreak | general
    severity: str                       # low | medium | high
    message: str
    source_name: Optional[str] = None
    risk_percent: Optional[float] = None
    state: Optional[str] = None
    district: Optional[str] = None
    block: Optional[str] = None
    village: Optional[str] = None
    status: str = "active"             # active | resolved
    created_by: str
    created_at: str


# ───────────────────────────────────────────
# FIRESTORE HELPERS
# ───────────────────────────────────────────

class DB:
    def __init__(self):
        self.db = firestore.client()

    def create(self, collection: str, data: dict, doc_id: str = None) -> str:
        if doc_id:
            self.db.collection(collection).document(doc_id).set(data)
            return doc_id
        ref = self.db.collection(collection).add(data)[1]
        return ref.id

    def get(self, collection: str, doc_id: str) -> dict:
        doc = self.db.collection(collection).document(doc_id).get()
        if doc.exists:
            return {"id": doc.id, **doc.to_dict()}
        return None

    def update(self, collection: str, doc_id: str, data: dict):
        self.db.collection(collection).document(doc_id).update(data)

    def delete(self, collection: str, doc_id: str):
        self.db.collection(collection).document(doc_id).delete()

    def query(self, collection: str, filters: list = None, order_by: str = None, limit: int = None) -> list:
        q = self.db.collection(collection)
        if filters:
            for field, op, value in filters:
                q = q.where(field, op, value)
        if order_by:
            q = q.order_by(order_by)
        if limit:
            q = q.limit(limit)
        return [{"id": doc.id, **doc.to_dict()} for doc in q.stream()]


# ───────────────────────────────────────────
# SINGLETON
# ───────────────────────────────────────────

init_firebase()
db = DB()