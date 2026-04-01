from fastapi import HTTPException, Depends
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from pydantic import BaseModel, EmailStr
from typing import Optional
from firebase_admin import auth as firebase_auth


bearer_scheme = HTTPBearer()


def get_current_user(
    credentials: HTTPAuthorizationCredentials = Depends(bearer_scheme),
) -> dict:
    """Verify Firebase ID token and return decoded token payload."""
    try:
        decoded = firebase_auth.verify_id_token(credentials.credentials)
        return decoded  # contains uid, email, and any custom claims
    except firebase_auth.ExpiredIdTokenError:
        raise HTTPException(status_code=401, detail="Token expired")
    except firebase_auth.InvalidIdTokenError:
        raise HTTPException(status_code=401, detail="Invalid token")
    except Exception as e:
        raise HTTPException(status_code=401, detail=f"Authentication failed: {str(e)}")


# --- Pydantic schema for syncing user profile after Firebase registration ---
class UserSync(BaseModel):
    full_name: str
    phone_number: Optional[str] = None
    role: str = "asha"           # asha | government
    state: str
    district: str
    block: Optional[str] = None
    village: Optional[str] = None
    preferred_language: str = "en"