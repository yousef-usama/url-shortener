"""
Unit tests for the URL Shortener Lambda function.
Uses moto to mock AWS services — no real AWS calls are made.
"""

import json
import os
import boto3
import pytest
from moto import mock_aws

# Set env vars before importing the handler
os.environ["TABLE_NAME"] = "test-urls"
os.environ["BASE_URL"] = "https://test.execute-api.eu-central-1.amazonaws.com/prod"


@pytest.fixture(autouse=True)
def aws_credentials(monkeypatch):
    """Ensure boto3 never talks to real AWS during tests."""
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "testing")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "testing")
    monkeypatch.setenv("AWS_SECURITY_TOKEN", "testing")
    monkeypatch.setenv("AWS_SESSION_TOKEN", "testing")
    monkeypatch.setenv("AWS_DEFAULT_REGION", "eu-central-1")


@pytest.fixture()
def dynamodb_table():
    """Create a mock DynamoDB table before each test, tear it down after."""
    with mock_aws():
        dynamodb = boto3.resource("dynamodb", region_name="eu-central-1")
        table = dynamodb.create_table(
            TableName="test-urls",
            KeySchema=[{"AttributeName": "short_code", "KeyType": "HASH"}],
            AttributeDefinitions=[{"AttributeName": "short_code", "AttributeType": "S"}],
            BillingMode="PAY_PER_REQUEST",
        )
        yield table


# ── Helpers ────────────────────────────────────────────────────────────────

def make_post_event(url: str) -> dict:
    return {
        "httpMethod": "POST",
        "path": "/shorten",
        "body": json.dumps({"url": url}),
    }


def make_get_event(code: str) -> dict:
    return {
        "httpMethod": "GET",
        "path": f"/{code}",
    }


# ── Tests ──────────────────────────────────────────────────────────────────

def test_create_short_url_returns_201(dynamodb_table):
    from handler import lambda_handler
    event = make_post_event("https://www.google.com")
    response = lambda_handler(event, {})

    assert response["statusCode"] == 201
    body = json.loads(response["body"])
    assert "short_url" in body
    assert "short_code" in body
    assert body["long_url"] == "https://www.google.com"


def test_short_url_stored_in_dynamodb(dynamodb_table):
    from handler import lambda_handler
    event = make_post_event("https://github.com/yousef-usama")
    response = lambda_handler(event, {})

    body = json.loads(response["body"])
    code = body["short_code"]

    item = dynamodb_table.get_item(Key={"short_code": code}).get("Item")
    assert item is not None
    assert item["long_url"] == "https://github.com/yousef-usama"


def test_redirect_returns_301(dynamodb_table):
    from handler import lambda_handler

    # First create a short URL
    post_response = lambda_handler(make_post_event("https://aws.amazon.com"), {})
    code = json.loads(post_response["body"])["short_code"]

    # Now test the redirect
    get_response = lambda_handler(make_get_event(code), {})
    assert get_response["statusCode"] == 301
    assert get_response["headers"]["Location"] == "https://aws.amazon.com"


def test_redirect_unknown_code_returns_404(dynamodb_table):
    from handler import lambda_handler
    response = lambda_handler(make_get_event("notreal"), {})
    assert response["statusCode"] == 404


def test_missing_url_field_returns_400(dynamodb_table):
    from handler import lambda_handler
    event = {
        "httpMethod": "POST",
        "path": "/shorten",
        "body": json.dumps({"not_url": "oops"}),
    }
    response = lambda_handler(event, {})
    assert response["statusCode"] == 400


def test_invalid_json_body_returns_400(dynamodb_table):
    from handler import lambda_handler
    event = {
        "httpMethod": "POST",
        "path": "/shorten",
        "body": "this is not json",
    }
    response = lambda_handler(event, {})
    assert response["statusCode"] == 400


def test_url_without_scheme_returns_400(dynamodb_table):
    from handler import lambda_handler
    event = make_post_event("google.com")
    response = lambda_handler(event, {})
    assert response["statusCode"] == 400


def test_unknown_route_returns_400(dynamodb_table):
    from handler import lambda_handler
    event = {"httpMethod": "DELETE", "path": "/shorten"}
    response = lambda_handler(event, {})
    assert response["statusCode"] == 400
