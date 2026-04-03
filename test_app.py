import pytest

from app import MIN_PASSWORD_LENGTH, _users, app


@pytest.fixture(autouse=True)
def clear_users():
    """Reset in-memory user store before each test."""
    _users.clear()
    yield
    _users.clear()


@pytest.fixture()
def client():
    app.config["TESTING"] = True
    with app.test_client() as c:
        yield c


# ---------------------------------------------------------------------------
# Happy path
# ---------------------------------------------------------------------------


def test_register_success(client):
    resp = client.post(
        "/register",
        json={"email": "user@example.com", "password": "a" * MIN_PASSWORD_LENGTH},
    )
    assert resp.status_code == 201
    assert resp.get_json()["message"] == "User registered successfully"


def test_register_password_exactly_min_length(client):
    resp = client.post(
        "/register",
        json={"email": "user@example.com", "password": "x" * MIN_PASSWORD_LENGTH},
    )
    assert resp.status_code == 201


# ---------------------------------------------------------------------------
# Email validation
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "bad_email",
    [
        "not-an-email",
        "missing@tld",
        "@nodomain.com",
        "spaces in@email.com",
        "",
        "double@@domain.com",
        None,
        123,
    ],
)
def test_invalid_email_returns_400(client, bad_email):
    resp = client.post(
        "/register",
        json={"email": bad_email, "password": "a" * MIN_PASSWORD_LENGTH},
    )
    assert resp.status_code == 400
    assert "email" in resp.get_json()["error"].lower()


# ---------------------------------------------------------------------------
# Password validation
# ---------------------------------------------------------------------------


def test_password_too_short_returns_400(client):
    resp = client.post(
        "/register",
        json={"email": "user@example.com", "password": "short"},
    )
    assert resp.status_code == 400
    assert "password" in resp.get_json()["error"].lower()


def test_password_one_char_below_minimum_returns_400(client):
    resp = client.post(
        "/register",
        json={"email": "user@example.com", "password": "x" * (MIN_PASSWORD_LENGTH - 1)},
    )
    assert resp.status_code == 400


def test_password_none_returns_400(client):
    resp = client.post(
        "/register",
        json={"email": "user@example.com", "password": None},
    )
    assert resp.status_code == 400


def test_password_integer_returns_400(client):
    resp = client.post(
        "/register",
        json={"email": "user@example.com", "password": 123456789012},
    )
    assert resp.status_code == 400


# ---------------------------------------------------------------------------
# Malformed request body
# ---------------------------------------------------------------------------


def test_non_json_body_returns_400(client):
    resp = client.post(
        "/register",
        data="not json",
        content_type="text/plain",
    )
    assert resp.status_code == 400


def test_json_array_body_returns_400(client):
    resp = client.post("/register", json=[{"email": "user@example.com"}])
    assert resp.status_code == 400


def test_missing_email_field_returns_400(client):
    resp = client.post(
        "/register",
        json={"password": "a" * MIN_PASSWORD_LENGTH},
    )
    assert resp.status_code == 400


def test_missing_password_field_returns_400(client):
    resp = client.post(
        "/register",
        json={"email": "user@example.com"},
    )
    assert resp.status_code == 400


# ---------------------------------------------------------------------------
# Duplicate email
# ---------------------------------------------------------------------------


def test_duplicate_email_returns_409(client):
    payload = {"email": "dup@example.com", "password": "a" * MIN_PASSWORD_LENGTH}
    client.post("/register", json=payload)
    resp = client.post("/register", json=payload)
    assert resp.status_code == 409
    assert "already" in resp.get_json()["error"].lower()
