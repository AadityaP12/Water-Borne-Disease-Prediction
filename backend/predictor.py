import joblib
import pandas as pd
import logging

from config import settings

logger = logging.getLogger(__name__)


# --- Load models once at startup ---
try:
    health_model = joblib.load(f"{settings.MODEL_PATH}lgb_health_model.pkl")
    logger.info("Health model loaded")
except Exception as e:
    health_model = None
    logger.warning(f"Health model not found: {e}")

try:
    water_model = joblib.load(f"{settings.MODEL_PATH}xgb_water_model.pkl")
    logger.info("Water model loaded")
except Exception as e:
    water_model = None
    logger.warning(f"Water model not found: {e}")


# --- Risk label helper ---
def risk_label(score: float) -> str:
    if score < settings.RISK_THRESHOLD_LOW:
        return "low"
    elif score < settings.RISK_THRESHOLD_HIGH:
        return "medium"
    return "high"


# -------------------------------------------------------------------
# STAGE 1: Health model — runs once for all persons
# -------------------------------------------------------------------
def predict_health(persons: list) -> dict:
    if health_model is None:
        raise RuntimeError("Health model not loaded")

    df = pd.DataFrame([{
        "sex":           p.get("sex"),
        "sanitation":    p.get("sanitation"),
        "water_source":  p.get("water_source"),
        "age":           p.get("age"),
        "diarrhea":      p.get("diarrhea", 0),
        "fatigue":       p.get("fatigue", 0),
        "vomiting":      p.get("vomiting", 0),
        "fever":         p.get("fever", 0),
        "jaundice":      p.get("jaundice", 0),
        "headache":      p.get("headache", 0),
        "loss_appetite": p.get("loss_of_appetite", 0),
        "muscle_aches":  p.get("muscle_aches", 0),
    } for p in persons])

    probs = health_model.predict(df)

    # Store age + all symptom values alongside ML results so that the
    # age-distribution and symptom-frequency dashboard charts can read them.
    predictions = [
        {
            "true_prob":        round(float(p), 4),
            "at_risk":          float(p) >= settings.RISK_THRESHOLD_LOW,
            "age":              persons[i].get("age"),
            "diarrhea":         persons[i].get("diarrhea", 0),
            "fatigue":          persons[i].get("fatigue", 0),
            "vomiting":         persons[i].get("vomiting", 0),
            "fever":            persons[i].get("fever", 0),
            "jaundice":         persons[i].get("jaundice", 0),
            "headache":         persons[i].get("headache", 0),
            "loss_of_appetite": persons[i].get("loss_of_appetite", 0),
            "muscle_aches":     persons[i].get("muscle_aches", 0),
        }
        for i, p in enumerate(probs)
    ]
    persons_with_symptoms = sum(1 for pred in predictions if pred["at_risk"])

    return {
        "persons_with_symptoms": persons_with_symptoms,
        "total_persons":         len(persons),
        "predictions":           predictions,
    }


# -------------------------------------------------------------------
# STAGE 2: Water model — runs once per water source
# -------------------------------------------------------------------
def predict_water(water_data: dict, persons_with_symptoms: int) -> dict:
    if water_model is None:
        raise RuntimeError("Water model not loaded")

    df = pd.DataFrame([{
        "source_type":           water_data.get("source_type"),
        "rainfall_24h_mm":       water_data.get("rainfall", 0.0),
        "temperature_C":         water_data.get("temperature"),
        "dissolved_oxygen_mgL":  water_data.get("dissolved_oxygen"),
        "chlorine_mgL":          water_data.get("chlorine"),
        "month":                 water_data.get("month"),
        "fecal_coliform_MPN":    water_data.get("fecal_coliform", 0.0),
        "season":                water_data.get("season"),
        "pH":                    water_data.get("ph"),
        "turbidity_NTU":         water_data.get("turbidity"),
        "persons_with_symptoms": persons_with_symptoms,
        "hardness_mgL":          water_data.get("hardness"),
        "nitrate_mgL":           water_data.get("nitrate"),
        "TDS_mgL":               water_data.get("tds"),
    }])

    risk_percent = float(water_model.predict(df)[0])
    risk_percent = max(0.0, min(100.0, risk_percent))   # clamp to valid range
    score = round(risk_percent / 100.0, 4)

    return {
        "risk_score":   score,
        "risk_level":   risk_label(score),
        "risk_percent": round(risk_percent, 2),
    }


# -------------------------------------------------------------------
# COMBINED: Full two-stage pipeline
# Accepts multiple water sources, runs water model for each one.
# -------------------------------------------------------------------
def run_pipeline(persons: list, water_sources: list) -> dict:
    """
    Stage 1: Run health model once for all persons.
    Stage 2: Run water model for each water source separately.
    Returns health result + list of water results.
    """
    health_result = predict_health(persons)

    water_results = []
    for source in water_sources:
        water_data = {
            "source_type":      source.get("source_type"),
            "ph":               source.get("ph"),
            "turbidity":        source.get("turbidity"),
            "temperature":      source.get("temperature"),
            "rainfall":         source.get("rainfall"),
            "dissolved_oxygen": source.get("dissolved_oxygen"),
            "chlorine":         source.get("chlorine"),
            "fecal_coliform":   source.get("fecal_coliform"),
            "hardness":         source.get("hardness"),
            "nitrate":          source.get("nitrate"),
            "tds":              source.get("tds"),
            "season":           source.get("season"),
            "month":            source.get("month"),
        }
        water_result = predict_water(water_data, health_result["persons_with_symptoms"])
        water_results.append({
            "source_name":  source.get("name", "Unknown"),
            "source_type":  source.get("source_type"),
            "risk_score":   water_result["risk_score"],
            "risk_level":   water_result["risk_level"],
            "risk_percent": water_result["risk_percent"],
        })

    return {
        "health":        health_result,
        "water_sources": water_results,
    }