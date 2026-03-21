from fastapi import FastAPI, HTTPException, Depends
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, EmailStr
from typing import Optional, List
from datetime import datetime, timezone
import uuid
import logging

from firebase_admin import messaging

from config import settings
from database import db, Col
from auth import (
    UserRegister, UserLogin, TokenResponse,
    hash_password, verify_password, create_token, get_current_user
)
from predictor import run_pipeline

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(
    title=settings.PROJECT_NAME,
    version=settings.VERSION,
    docs_url="/docs" if settings.DEBUG else None,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.ALLOWED_HOSTS,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# ───────────────────────────────────────────
# FCM HELPER
# ───────────────────────────────────────────

def send_fcm_notification(tokens: list, title: str, body: str, data: dict = None):
    if not tokens:
        return
    messages = [
        messaging.Message(
            notification=messaging.Notification(title=title, body=body),
            data={k: str(v) for k, v in (data or {}).items()},
            token=token,
        )
        for token in tokens
    ]
    try:
        response = messaging.send_each(messages)
        logger.info(f"FCM: {response.success_count} sent, {response.failure_count} failed")
    except Exception as e:
        logger.error(f"FCM send failed: {e}")


def notify_district(state: str, district: str, title: str, body: str, data: dict = None):
    try:
        users = db.query(Col.USERS, filters=[
            ("state",    "==", state),
            ("district", "==", district),
        ])
        logger.info(f"notify_district: state={state}, district={district}, found {len(users)} users")
        tokens = [u["fcm_token"] for u in users if u.get("fcm_token")]
        logger.info(f"notify_district: {len(tokens)} users have FCM tokens, sending notification")
        send_fcm_notification(tokens, title, body, data)
    except Exception as e:
        logger.error(f"notify_district failed: {e}")


# ───────────────────────────────────────────
# AUTH ROUTES
# ───────────────────────────────────────────

@app.post(f"{settings.API_V1_STR}/auth/register")
async def register(user: UserRegister):
    existing = db.query(Col.USERS, filters=[("email", "==", user.email)])
    if existing:
        raise HTTPException(status_code=400, detail="Email already registered")

    user_id = str(uuid.uuid4())
    db.create(Col.USERS, {
        "uid":                user_id,
        "email":              user.email,
        "password_hash":      hash_password(user.password),
        "full_name":          user.full_name,
        "phone_number":       user.phone_number,
        "role":               user.role,
        "state":              user.state,
        "district":           user.district,
        "block":              user.block,
        "village":            user.village,
        "preferred_language": user.preferred_language,
        "fcm_token":          None,
        "created_at":         datetime.now(timezone.utc).isoformat(),
    }, doc_id=user_id)

    token = create_token({"uid": user_id, "role": user.role})
    return {"access_token": token, "token_type": "bearer", "user_id": user_id, "role": user.role}


@app.post(f"{settings.API_V1_STR}/auth/login")
async def login(credentials: UserLogin):
    users = db.query(Col.USERS, filters=[("email", "==", credentials.email)])
    if not users:
        raise HTTPException(status_code=401, detail="Invalid email or password")

    user = users[0]
    if not verify_password(credentials.password, user["password_hash"]):
        raise HTTPException(status_code=401, detail="Invalid email or password")

    token = create_token({"uid": user["uid"], "role": user["role"]})
    return {"access_token": token, "token_type": "bearer", "user_id": user["uid"], "role": user["role"]}


@app.get(f"{settings.API_V1_STR}/auth/me")
async def get_me(current_user: dict = Depends(get_current_user)):
    user = db.get(Col.USERS, current_user["uid"])
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    user.pop("password_hash", None)
    return user


# FIX: renamed from /auth/fcm-token, field renamed from fcm_token to push_token
# to match what asha_dashboard.dart sends: POST /auth/update-push-token { push_token: ... }
class FCMTokenUpdate(BaseModel):
    push_token: str


@app.post(f"{settings.API_V1_STR}/auth/update-push-token")
async def update_push_token(body: FCMTokenUpdate, current_user: dict = Depends(get_current_user)):
    db.update(Col.USERS, current_user["uid"], {"fcm_token": body.push_token})
    return {"status": "fcm token updated"}


# FIX: added missing endpoint — asha_dashboard.dart profile tab calls this
class ProfileUpdate(BaseModel):
    current_password: str
    state: Optional[str] = None
    district: Optional[str] = None
    new_password: Optional[str] = None


@app.post(f"{settings.API_V1_STR}/auth/update-profile")
async def update_profile(body: ProfileUpdate, current_user: dict = Depends(get_current_user)):
    user = db.get(Col.USERS, current_user["uid"])
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    if not verify_password(body.current_password, user["password_hash"]):
        raise HTTPException(status_code=401, detail="Incorrect current password")

    updates: dict = {}
    if body.state:        updates["state"]         = body.state
    if body.district:     updates["district"]      = body.district
    if body.new_password: updates["password_hash"] = hash_password(body.new_password)

    if updates:
        db.update(Col.USERS, current_user["uid"], updates)
    return {"status": "profile updated"}


# ───────────────────────────────────────────
# DATA ROUTES
# ───────────────────────────────────────────

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
    season: Optional[str] = None
    month: Optional[int] = None


class HealthSubmission(BaseModel):
    house_id: str
    persons: List[dict]
    water_sources: List[WaterSourceInput]
    state: Optional[str] = None
    district: Optional[str] = None
    block: Optional[str] = None
    village: Optional[str] = None


@app.post(f"{settings.API_V1_STR}/data/submit")
async def submit_data(submission: HealthSubmission, current_user: dict = Depends(get_current_user)):
    """
    Main data submission endpoint.
    ASHA worker submits household health data + multiple water sources.
    Runs the full ML pipeline for each water source.
    Sends FCM alert if any source is high risk.
    """
    from predictor import predict_health, predict_water

    # Stage 1: Run health model once for all persons
    health_result = predict_health(submission.persons)

    # Stage 2: Run water model for each water source
    water_results = []
    highest_risk_source = None
    highest_risk_percent = 0

    for source in submission.water_sources:
        water_data = {
            "source_type":       source.source_type,
            "ph":                source.ph,
            "turbidity":         source.turbidity,
            "temperature":       source.temperature,
            "rainfall":          source.rainfall,
            "dissolved_oxygen":  source.dissolved_oxygen,
            "chlorine":          source.chlorine,
            "fecal_coliform":    source.fecal_coliform,
            "hardness":          source.hardness,
            "nitrate":           source.nitrate,
            "tds":               source.tds,
            "season":            source.season,
            "month":             source.month,
        }
        water_result = predict_water(water_data, health_result["persons_with_symptoms"])
        water_results.append({
            "source_name":  source.name,
            "source_type":  source.source_type,
            "risk_score":   water_result["risk_score"],
            "risk_level":   water_result["risk_level"],
            "risk_percent": water_result["risk_percent"],
        })

        if water_result["risk_percent"] > highest_risk_percent:
            highest_risk_percent = water_result["risk_percent"]
            highest_risk_source = {
                "name":        source.name,
                "source_type": source.source_type,
                **water_result,
            }

    # Store one record per submission (with all water source results)
    record_id = str(uuid.uuid4())
    record = {
        "id":                    record_id,
        "submitted_by":          current_user["uid"],
        "house_id":              submission.house_id,
        "state":                 submission.state,
        "district":              submission.district,
        "block":                 submission.block,
        "village":               submission.village,
        "total_persons":         health_result["total_persons"],
        "persons_with_symptoms": health_result["persons_with_symptoms"],
        # predictions now include age + symptom values so dashboard charts work
        "health_predictions":    health_result["predictions"],
        "water_sources":         water_results,
        # backward-compat top-level fields — highest risk source
        "water_source_name":     highest_risk_source["name"]        if highest_risk_source else "",
        "water_risk_level":      highest_risk_source["risk_level"]  if highest_risk_source else "low",
        "water_risk_percent":    highest_risk_source["risk_percent"] if highest_risk_source else 0,
        "submitted_at":          datetime.now(timezone.utc).isoformat(),
    }
    db.create(Col.HEALTH_DATA, record, doc_id=record_id)

    # Auto-create alert + FCM notification for each high-risk source
    alerts_created = []
    for wr in water_results:
        if wr["risk_level"] == "high":
            alert_id = str(uuid.uuid4())
            db.create(Col.ALERTS, {
                "id":           alert_id,
                "type":         "water_contamination",
                "severity":     "high",
                "risk_percent": wr["risk_percent"],
                "source_name":  wr["source_name"],
                "state":        submission.state,
                "district":     submission.district,
                "block":        submission.block,
                "village":      submission.village,
                "status":       "active",
                "created_by":   current_user["uid"],
                "created_at":   datetime.now(timezone.utc).isoformat(),
            }, doc_id=alert_id)
            alerts_created.append(alert_id)

            if submission.state and submission.district:
                notify_district(
                    state=submission.state,
                    district=submission.district,
                    title="⚠️ Water Contamination Alert",
                    body=f"High risk at {wr['source_name']} in {submission.village or submission.district}. Risk: {wr['risk_percent']}%",
                    data={
                        "alert_id":     alert_id,
                        "risk_level":   "high",
                        "risk_percent": wr["risk_percent"],
                        "source_name":  wr["source_name"],
                    }
                )

    return {
        "record_id":      record_id,
        "health":         health_result,
        "water_sources":  water_results,
        "alerts_created": len(alerts_created),
    }


@app.get(f"{settings.API_V1_STR}/data/history")
async def get_history(current_user: dict = Depends(get_current_user)):
    records = db.query(
        Col.HEALTH_DATA,
        filters=[("submitted_by", "==", current_user["uid"])],
        order_by="submitted_at",
        limit=50
    )
    return {"records": records}


# ───────────────────────────────────────────
# ALERTS ROUTES
# ───────────────────────────────────────────

class AlertCreate(BaseModel):
    type: str
    severity: str
    message: str
    state: Optional[str] = None
    district: Optional[str] = None
    block: Optional[str] = None
    village: Optional[str] = None


@app.get(f"{settings.API_V1_STR}/alerts")
async def get_alerts(current_user: dict = Depends(get_current_user)):
    alerts = db.query(Col.ALERTS, filters=[("status", "==", "active")], order_by="created_at", limit=100)
    return {"alerts": alerts}


@app.post(f"{settings.API_V1_STR}/alerts")
async def create_alert(alert: AlertCreate, current_user: dict = Depends(get_current_user)):
    alert_id = str(uuid.uuid4())
    db.create(Col.ALERTS, {
        "id":         alert_id,
        "type":       alert.type,
        "severity":   alert.severity,
        "message":    alert.message,
        "state":      alert.state,
        "district":   alert.district,
        "block":      alert.block,
        "village":    alert.village,
        "status":     "active",
        "created_by": current_user["uid"],
        "created_at": datetime.now(timezone.utc).isoformat(),
    }, doc_id=alert_id)
    return {"alert_id": alert_id, "status": "created"}


@app.patch(f"{settings.API_V1_STR}/alerts/{{alert_id}}/resolve")
async def resolve_alert(alert_id: str, current_user: dict = Depends(get_current_user)):
    db.update(Col.ALERTS, alert_id, {"status": "resolved"})
    return {"alert_id": alert_id, "status": "resolved"}


# ───────────────────────────────────────────
# DASHBOARD ROUTES
# ───────────────────────────────────────────

@app.get(f"{settings.API_V1_STR}/dashboard/overview")
async def dashboard_overview(current_user: dict = Depends(get_current_user)):
    records = db.query(Col.HEALTH_DATA, limit=500)
    alerts  = db.query(Col.ALERTS, filters=[("status", "==", "active")])

    total_submissions = len(records)
    total_persons     = sum(r.get("total_persons", 0) for r in records)
    total_at_risk     = sum(r.get("persons_with_symptoms", 0) for r in records)

    high = medium = low = 0
    for r in records:
        sources = r.get("water_sources", [])
        if sources:
            for s in sources:
                level = s.get("risk_level", "low")
                if level == "high":   high   += 1
                elif level == "medium": medium += 1
                else:                 low    += 1
        else:
            level = r.get("water_risk_level", "low")
            if level == "high":   high   += 1
            elif level == "medium": medium += 1
            else:                 low    += 1

    return {
        "total_submissions":    total_submissions,
        "total_persons":        total_persons,
        "total_at_risk":        total_at_risk,
        "active_alerts":        len(alerts),
        "water_risk_breakdown": {"high": high, "medium": medium, "low": low},
        "recent_records":       records[-10:],
    }


# ───────────────────────────────────────────
# CHART DATA ROUTES
# ───────────────────────────────────────────

@app.get(f"{settings.API_V1_STR}/data/age-distribution")
async def age_distribution(current_user: dict = Depends(get_current_user)):
    """Age group distribution across all submitted persons."""
    records = db.query(Col.HEALTH_DATA, limit=500)
    buckets = {"0-17": 0, "18-34": 0, "35-49": 0, "50-64": 0, "65+": 0}
    for r in records:
        for pred in r.get("health_predictions", []):
            age = pred.get("age")
            if age is None:
                continue
            if age <= 17:   buckets["0-17"]  += 1
            elif age <= 34: buckets["18-34"] += 1
            elif age <= 49: buckets["35-49"] += 1
            elif age <= 64: buckets["50-64"] += 1
            else:           buckets["65+"]   += 1
    return {
        "labels":   list(buckets.keys()),
        "datasets": [{"data": list(buckets.values())}],
    }


@app.get(f"{settings.API_V1_STR}/data/symptom-frequency")
async def symptom_frequency(current_user: dict = Depends(get_current_user)):
    """How many persons reported each symptom (severity > 0)."""
    records = db.query(Col.HEALTH_DATA, limit=500)
    symptom_keys = [
        "diarrhea", "fatigue", "vomiting", "fever",
        "jaundice", "headache", "loss_of_appetite", "muscle_aches",
    ]
    counts = {s: 0 for s in symptom_keys}
    for r in records:
        for person in r.get("health_predictions", []):
            for s in symptom_keys:
                if int(person.get(s, 0) or 0) > 0:
                    counts[s] += 1
    labels = [s.replace("_", " ").title() for s in symptom_keys]
    return {
        "labels":   labels,
        "datasets": [{"data": [counts[s] for s in symptom_keys]}],
    }


@app.get(f"{settings.API_V1_STR}/data/water-source-distribution")
async def water_source_distribution(current_user: dict = Depends(get_current_user)):
    """Count of each water source type across all submissions."""
    records = db.query(Col.HEALTH_DATA, limit=500)
    counts: dict = {}
    for r in records:
        for ws in r.get("water_sources", []):
            stype = ws.get("source_type", "unknown")
            counts[stype] = counts.get(stype, 0) + 1
    colors = ["#FF6384", "#36A2EB", "#FFCE56", "#4BC0C0", "#9966FF", "#FF9F40", "#C9CBCF", "#7BC8A4"]
    return [
        {
            "name":       name.replace("_", " ").title(),
            "population": count,
            "color":      colors[i % len(colors)],
        }
        for i, (name, count) in enumerate(counts.items())
    ]


@app.get(f"{settings.API_V1_STR}/data/workers")
async def get_workers(current_user: dict = Depends(get_current_user)):
    """List of active ASHA workers with their submission counts."""
    workers = db.query(Col.USERS, filters=[("role", "==", "asha")])
    records = db.query(Col.HEALTH_DATA, limit=500)
    submission_counts = {}
    for r in records:
        uid = r.get("submitted_by", "")
        submission_counts[uid] = submission_counts.get(uid, 0) + 1
    result = [
        {
            "uid":         w["uid"],
            "full_name":   w.get("full_name", ""),
            "district":    w.get("district", ""),
            "state":       w.get("state", ""),
            "submissions": submission_counts.get(w["uid"], 0),
        }
        for w in workers
    ]
    result.sort(key=lambda x: x["submissions"], reverse=True)
    return {"workers": result, "total": len(result)}


# ───────────────────────────────────────────
# HEALTH CHECK
# ───────────────────────────────────────────

@app.get("/health")
async def health():
    return {"status": "ok", "version": settings.VERSION}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=settings.DEBUG)