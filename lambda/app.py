import json
import os
import uuid

import boto3

table = boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])


def response(status, body):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body, default=str, ensure_ascii=False),
    }


def handler(event, context):
    route = event["routeKey"]

    # POST /items : データを保存
    if route == "POST /items":
        try:
            body = json.loads(event.get("body") or "{}")
        except json.JSONDecodeError:
            return response(400, {"message": "invalid JSON"})

        item = {"id": str(uuid.uuid4()), "data": body}
        table.put_item(Item=item)
        return response(201, item)
    
    # DELETE /items/{id} : データを削除
    if route == "DELETE /items/{id}":
        try:
            item_id = event["pathParameters"]["id"]
            result = table.delete_item(Key={"id": item_id}, ReturnValues="ALL_OLD")
            if "Attributes" not in result:
                return response(404, {"message": "not found"})
            return response(200, {"message": "deleted"})
        except Exception as e:
            return response(500, {"message": str(e)})  

    # GET /items/{id} : データを取得
    if route == "GET /items/{id}":
        item_id = event["pathParameters"]["id"]
        result = table.get_item(Key={"id": item_id})
        if "Item" not in result:
            return response(404, {"message": "not found"})
        return response(200, result["Item"])

    return response(404, {"message": "not found"})
