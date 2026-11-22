# AWS Serverless API (Terraform)

Terraform で構築する、Cognito 認証付きの小さな HTTP API です。API Gateway のリクエストを Lambda が処理し、DynamoDB にアイテムを保存・取得・削除します。

## 構成

- **API Gateway HTTP API**: `POST /items`、`GET /items/{id}`、`DELETE /items/{id}` を提供。すべて Cognito JWT 認証が必要です。
- **AWS Lambda (Python 3.12)**: `lambda/app.py` を実行し、DynamoDB を操作します。
- **Amazon DynamoDB**: オンデマンド課金、保存時暗号化、Point-in-Time Recovery を有効にしたテーブルです。
- **Amazon Cognito**: 管理者によるユーザー作成と JWT 発行を担当します。
- **Amazon CloudWatch**: API と Lambda のログを14日間保存し、5xx と Lambda エラーのアラームを作成します。

Terraform の構成は機能ごとに `modules/` に分かれています。各モジュールは `main.tf` から呼び出します。

```text
modules/
├── cognito/      # ユーザープールとアプリクライアント
├── dynamodb/     # アイテム保存テーブル
├── http_api/     # HTTP API、JWT 認証、ルート、アクセスログ
├── lambda/       # 関数、IAM ロール、ログ
└── monitoring/   # CloudWatch アラーム
lambda/app.py     # API の処理
```

## 必要なもの

- Terraform 1.5 以上
- AWS CLI と、対象アカウントへの認証設定
- `ap-northeast-1` でリソースを作成できる AWS 権限（リージョンは `region` 変数で変更できます）

## デプロイ

```sh
terraform init
terraform plan
terraform apply
```

`project` と `region` は任意で変更できます。

```sh
terraform apply -var="project=my-serverless" -var="region=ap-northeast-1"
```

適用後、接続情報を確認します。

```sh
terraform output -raw api_url
terraform output -raw user_pool_id
terraform output -raw client_id
```

## API の利用

ユーザーは Cognito の管理者 API で作成し、`USER_PASSWORD_AUTH` で ID トークンを取得します。API URL、ユーザープール ID、クライアント ID は Terraform output から取得できます。トークンを `Authorization` ヘッダーに設定してリクエストします。

```sh
API_URL="$(terraform output -raw api_url)"
# ID_TOKEN は Cognito の USER_PASSWORD_AUTH で取得した ID トークンに置き換えます。

curl -X POST "$API_URL/items" \
  -H "Authorization: $ID_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"title":"hello"}'

curl "$API_URL/items/$ITEM_ID" -H "Authorization: $ID_TOKEN"

curl -X DELETE "$API_URL/items/$ITEM_ID" -H "Authorization: $ID_TOKEN"
```

作成レスポンスに含まれる `id` を `$ITEM_ID` として使います。