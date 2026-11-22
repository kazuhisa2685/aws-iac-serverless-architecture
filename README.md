# AWS Serverless Items

Terraform で構築する Cognito 認証付きのサンプルアプリです。ブラウザーから自分のアイテムを作成・一覧・取得・更新・削除できます。

## 構成

- **Amazon S3 + CloudFront**: HTML/CSS/JavaScript を配信します。S3 バケットは非公開にし、CloudFront OAC からのみ読み取れるようにします。
- **Amazon Cognito**: 管理者が作成したユーザーをマネージドログインと PKCE で認証します。
- **API Gateway HTTP API**: Cognito JWT で保護した API を提供し、フロントエンドの CloudFront オリジンだけを CORS で許可します。
- **AWS Lambda (Python 3.12)**: API を処理します。
- **Amazon DynamoDB**: オンデマンド課金、保存時暗号化、Point-in-Time Recovery を使用します。ユーザーごとの一覧用 GSI があります。
- **Amazon CloudWatch**: API と Lambda のログを14日間保存し、5xx と Lambda エラーのアラームを作成します（通知先は未設定です）。

所有者 ID は API Gateway が検証した JWT の `sub` から取得します。作成時に DynamoDB に保存し、一覧・取得・更新・削除を所有者に限定します。更新と削除は DynamoDB の条件式でも所有者を確認します。

```text
frontend/             # ブラウザー UI
lambda/app.py         # API と所有者チェック
modules/
├── cognito/          # ユーザープール、アプリクライアント、ログインドメイン
├── dynamodb/         # アイテムテーブル、所有者 GSI
├── http_api/         # HTTP API、JWT 認証、CORS、ルート
├── lambda/           # 関数、IAM 権限、ログ
├── monitoring/       # CloudWatch アラーム
├── web_assets/       # フロントエンドファイルの S3 配置
└── web_hosting/      # 非公開 S3 と CloudFront OAC
```

## 必要なもの

- Terraform 1.5 以上
- AWS CLI と対象アカウントへの認証設定
- `ap-northeast-1` に必要なリソースを作成できる AWS 権限

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

適用後、`terraform output -raw frontend_url` を開き、Cognito でサインインします。ユーザーは Cognito 管理者が作成してください。API URL などは次の output で確認できます。

```sh
terraform output -raw frontend_url
terraform output -raw api_url
terraform output -raw user_pool_id
terraform output -raw client_id
```

## API

すべてのルートで `Authorization` ヘッダーに Cognito ID トークンが必要です。

| Method | Path | 説明 |
| --- | --- | --- |
| `POST` | `/items` | JSON 本文を自分のアイテムとして作成 |
| `GET` | `/items` | 自分のアイテムを一覧取得。`limit`（1〜100）と `nextToken` でページング |
| `GET` | `/items/{id}` | 自分のアイテムを取得 |
| `PUT` | `/items/{id}` | JSON 本文で自分のアイテムを更新 |
| `DELETE` | `/items/{id}` | 自分のアイテムを削除 |

一覧 API は `{ "items": [...], "nextToken": "..." }` を返します。`nextToken` が `null` の場合、その後のページはありません。

## 削除

```sh
terraform destroy
```

この操作は Terraform 管理下の AWS リソースとデータを削除します。必要なデータを事前に退避してください。

## 注意

デプロイ時に既存の DynamoDB テーブルへ所有者 GSI を追加します。既存レコードには所有者情報がないため、新しい所有者チェックでは一覧に表示されず、個別取得・更新・削除もできません。必要な既存データは事前にバックアップし、所有者を安全に特定できる方法で移行してください。
