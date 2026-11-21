# 1. ユーザー作成（値は自分のものに置き換え）
aws cognito-idp admin-create-user --user-pool-id <user_pool_id> \
  --username test@example.com --message-action SUPPRESS

aws cognito-idp admin-set-user-password --user-pool-id <user_pool_id> \
  --username test@example.com --password 'MyPassw0rd!2026' --permanent

# 2. トークン取得
TOKEN=$(aws cognito-idp initiate-auth --auth-flow USER_PASSWORD_AUTH \
  --client-id <client_id> \
  --auth-parameters USERNAME=test@example.com,PASSWORD='MyPassw0rd!2026' \
  --query 'AuthenticationResult.IdToken' --output text)

# 3. データ登録
curl -X POST <api_url>/items \
  -H "Authorization: $TOKEN" -H "Content-Type: application/json" \
  -d '{"title":"hello"}'

# 4. データ取得（3で返ってきた id を指定）
curl <api_url>/items/<id> -H "Authorization: $TOKEN"