import base64
import binascii
import json
import logging
import os
import uuid
from datetime import datetime, timezone
from decimal import Decimal

import boto3
from boto3.dynamodb.conditions import Attr, Key
from botocore.exceptions import ClientError

table = boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])
logger = logging.getLogger()
logger.setLevel(logging.INFO)


def json_default(value):
    if isinstance(value, Decimal):
        return int(value) if value == value.to_integral_value() else float(value)
    raise TypeError(f"Unsupported JSON value: {type(value).__name__}")


def response(status, body):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body, default=json_default, ensure_ascii=False),
    }


def get_owner_id(event):
    claims = (
        event.get("requestContext", {})
        .get("authorizer", {})
        .get("jwt", {})
        .get("claims", {})
    )
    return claims.get("sub")


def encode_cursor(last_evaluated_key):
    if not last_evaluated_key:
        return None
    raw = json.dumps(last_evaluated_key, default=json_default).encode("utf-8")
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def decode_cursor(token, owner_id):
    if not token:
        return None
    try:
        padded = token + "=" * (-len(token) % 4)
        cursor = json.loads(base64.urlsafe_b64decode(padded).decode("utf-8"))
    except (ValueError, UnicodeDecodeError, json.JSONDecodeError, binascii.Error):
        raise ValueError("invalid nextToken") from None

    if (
        not isinstance(cursor, dict)
        or cursor.get("owner_id") != owner_id
        or not all(key in cursor for key in ("created_at", "id"))
    ):
        raise ValueError("invalid nextToken")
    return cursor


def list_items(event, owner_id):
    query = event.get("queryStringParameters") or {}
    try:
        limit = int(query.get("limit", "25"))
    except (TypeError, ValueError):
        return response(400, {"message": "limit must be an integer from 1 to 100"})
    if not 1 <= limit <= 100:
        return response(400, {"message": "limit must be an integer from 1 to 100"})

    try:
        cursor = decode_cursor(query.get("nextToken"), owner_id)
    except ValueError as error:
        return response(400, {"message": str(error)})

    params = {
        "IndexName": "owner_id-created_at-index",
        "KeyConditionExpression": Key("owner_id").eq(owner_id),
        "Limit": limit,
        "ScanIndexForward": False,
    }
    if cursor:
        params["ExclusiveStartKey"] = cursor

    try:
        result = table.query(**params)
    except ClientError:
        logger.exception("DynamoDB list query failed")
        return response(500, {"message": "internal server error"})

    items = [
        {"id": item["id"], "data": item["data"], "createdAt": item["created_at"]}
        for item in result.get("Items", [])
    ]
    return response(
        200,
        {"items": items, "nextToken": encode_cursor(result.get("LastEvaluatedKey"))},
    )


def handler(event, context):
    logger.info("event: %s", json.dumps(event, default=json_default, ensure_ascii=False))
    owner_id = get_owner_id(event)
    if not owner_id:
        return response(401, {"message": "unauthorized"})

    route = event.get("routeKey")

    if route == "POST /items":
        try:
            body = json.loads(event.get("body") or "{}", parse_float=Decimal)
        except json.JSONDecodeError:
            return response(400, {"message": "invalid JSON"})

        created_at = datetime.now(timezone.utc).isoformat(timespec="milliseconds")
        item = {
            "id": str(uuid.uuid4()),
            "owner_id": owner_id,
            "created_at": created_at,
            "data": body,
        }
        try:
            table.put_item(Item=item)
        except ClientError:
            logger.exception("DynamoDB create failed")
            return response(500, {"message": "internal server error"})
        return response(
            201,
            {"id": item["id"], "data": body, "createdAt": created_at},
        )

    if route == "GET /items":
        return list_items(event, owner_id)

    if route == "GET /items/{id}":
        item_id = (event.get("pathParameters") or {}).get("id")
        if not item_id:
            return response(400, {"message": "missing item id"})
        try:
            result = table.get_item(Key={"id": item_id})
        except ClientError:
            logger.exception("DynamoDB get failed")
            return response(500, {"message": "internal server error"})

        item = result.get("Item")
        if not item or item.get("owner_id") != owner_id:
            return response(404, {"message": "not found"})
        return response(
            200,
            {"id": item["id"], "data": item["data"], "createdAt": item["created_at"]},
        )

    if route == "PUT /items/{id}":
        item_id = (event.get("pathParameters") or {}).get("id")
        if not item_id:
            return response(400, {"message": "missing item id"})
        try:
            body = json.loads(event.get("body") or "{}", parse_float=Decimal)
        except json.JSONDecodeError:
            return response(400, {"message": "invalid JSON"})

        try:
            result = table.update_item(
                Key={"id": item_id},
                UpdateExpression="SET #data = :data",
                ExpressionAttributeNames={"#data": "data"},
                ExpressionAttributeValues={":data": body},
                ConditionExpression=Attr("owner_id").eq(owner_id),
                ReturnValues="ALL_NEW",
            )
        except ClientError as error:
            if error.response.get("Error", {}).get("Code") == "ConditionalCheckFailedException":
                return response(404, {"message": "not found"})
            logger.exception("DynamoDB update failed")
            return response(500, {"message": "internal server error"})

        item = result["Attributes"]
        return response(
            200,
            {"id": item["id"], "data": item["data"], "createdAt": item["created_at"]},
        )

    if route == "DELETE /items/{id}":
        item_id = (event.get("pathParameters") or {}).get("id")
        if not item_id:
            return response(400, {"message": "missing item id"})
        try:
            table.delete_item(
                Key={"id": item_id},
                ConditionExpression=Attr("owner_id").eq(owner_id),
            )
        except ClientError as error:
            if error.response.get("Error", {}).get("Code") == "ConditionalCheckFailedException":
                return response(404, {"message": "not found"})
            logger.exception("DynamoDB delete failed")
            return response(500, {"message": "internal server error"})
        return response(200, {"message": "deleted"})

    return response(404, {"message": "not found"})
