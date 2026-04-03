import re
from typing import Any

from flask import Flask, jsonify, request

app = Flask(__name__)

_EMAIL_RE = re.compile(r"^[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}$")
MIN_PASSWORD_LENGTH = 12

# In-memory user store (replace with a real database in production)
_users: dict[str, str] = {}


def _validate_registration(email: Any, password: Any) -> str | None:
    """Return an error message string, or None when inputs are valid."""
    if not isinstance(email, str) or not _EMAIL_RE.match(email):
        return "Invalid email format"
    if not isinstance(password, str) or len(password) < MIN_PASSWORD_LENGTH:
        return f"Password must be at least {MIN_PASSWORD_LENGTH} characters"
    return None


@app.route("/register", methods=["POST"])
def register() -> Any:
    data: Any = request.get_json(silent=True)
    if not isinstance(data, dict):
        return jsonify({"error": "Request body must be JSON"}), 400

    error = _validate_registration(data.get("email"), data.get("password"))
    if error:
        return jsonify({"error": error}), 400

    email: str = data["email"]
    password: str = data["password"]

    if email in _users:
        return jsonify({"error": "Email already registered"}), 409

    _users[email] = password
    return jsonify({"message": "User registered successfully"}), 201
