import json
import os
import string
import random
import boto3
from boto3.dynamodb.conditions import Key

dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ["TABLE_NAME"])
BASE_URL = os.environ["BASE_URL"]  # injected by Terraform


def generate_short_code(length=7):
    chars = string.ascii_letters + string.digits
    return "".join(random.choices(chars, k=length))


def create_short_url(long_url: str) -> dict:
    # Retry on the tiny chance of a collision
    for _ in range(5):
        code = generate_short_code()
        response = table.get_item(Key={"short_code": code})
        if "Item" not in response:
            break
    else:
        return {"statusCode": 500, "body": json.dumps({"error": "Could not generate unique code. Try again."})}

    table.put_item(Item={"short_code": code, "long_url": long_url})
    return {
        "statusCode": 201,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({
            "short_url": f"{BASE_URL}/{code}",
            "short_code": code,
            "long_url": long_url,
        }),
    }


def redirect(short_code: str) -> dict:
    response = table.get_item(Key={"short_code": short_code})
    item = response.get("Item")
    if not item:
        return {
            "statusCode": 404,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"error": "Short URL not found."}),
        }
    return {
        "statusCode": 301,
        "headers": {"Location": item["long_url"]},
        "body": "",
    }


def lambda_handler(event, context):
    method = event.get("httpMethod", "")
    path   = event.get("path", "/")

    # POST /shorten  →  create a short URL
    if method == "POST" and path == "/shorten":
        try:
            body = json.loads(event.get("body") or "{}")
            long_url = body.get("url", "").strip()
        except json.JSONDecodeError:
            return {"statusCode": 400, "body": json.dumps({"error": "Invalid JSON body."})}

        if not long_url:
            return {"statusCode": 400, "body": json.dumps({"error": "Missing 'url' field in request body."})}
        if not long_url.startswith(("http://", "https://")):
            return {"statusCode": 400, "body": json.dumps({"error": "URL must start with http:// or https://"})}

        return create_short_url(long_url)

    # GET /{code}  →  redirect to the original URL
    if method == "GET" and path != "/":
        short_code = path.lstrip("/")
        return redirect(short_code)

    return {
        "statusCode": 400,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"error": "Invalid route. Use POST /shorten or GET /{code}"}),
    }
