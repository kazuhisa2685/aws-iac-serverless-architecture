const CONFIG = Object.freeze({
  apiUrl: "__API_URL__",
  region: "__REGION__",
  clientId: "__CLIENT_ID__",
  cognitoDomain: "__COGNITO_DOMAIN__",
});

const callbackUrl = window.location.origin;
const loginPanel = document.querySelector("#login-panel");
const appPanel = document.querySelector("#app-panel");
const statusNode = document.querySelector("#status");
const itemsNode = document.querySelector("#items-list");
let idToken = null;
let previousCursors = [];
let activeCursor = null;
let editingItemId = null;

function setStatus(message, kind = "info") {
  statusNode.textContent = message;
  statusNode.dataset.kind = kind;
}

function randomVerifier() {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return btoa(String.fromCharCode(...bytes))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");
}

function base64Url(bytes) {
  return btoa(String.fromCharCode(...new Uint8Array(bytes)))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");
}

async function beginSignIn() {
  const verifier = randomVerifier();
  const challenge = base64Url(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier)));
  const stateBytes = crypto.getRandomValues(new Uint8Array(24));
  const state = base64Url(stateBytes);
  sessionStorage.setItem("pkce_verifier", verifier);
  sessionStorage.setItem("oauth_state", state);

  const authorizeUrl = new URL(`${CONFIG.cognitoDomain}/oauth2/authorize`);
  authorizeUrl.search = new URLSearchParams({
    response_type: "code",
    client_id: CONFIG.clientId,
    redirect_uri: callbackUrl,
    scope: "openid",
    code_challenge: challenge,
    code_challenge_method: "S256",
    state,
  });
  window.location.assign(authorizeUrl);
}

async function finishSignIn() {
  const currentUrl = new URL(window.location.href);
  const code = currentUrl.searchParams.get("code");
  if (!code) return false;

  const returnedState = currentUrl.searchParams.get("state");
  const expectedState = sessionStorage.getItem("oauth_state");
  const verifier = sessionStorage.getItem("pkce_verifier");
  sessionStorage.removeItem("oauth_state");
  sessionStorage.removeItem("pkce_verifier");
  if (!returnedState || returnedState !== expectedState || !verifier) {
    throw new Error("サインイン状態を確認できませんでした。もう一度お試しください。");
  }

  const tokenUrl = `${CONFIG.cognitoDomain}/oauth2/token`;
  const body = new URLSearchParams({
    grant_type: "authorization_code",
    client_id: CONFIG.clientId,
    code,
    redirect_uri: callbackUrl,
    code_verifier: verifier,
  });
  const result = await fetch(tokenUrl, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body,
  });
  const tokens = await result.json();
  if (!result.ok || !tokens.id_token) {
    throw new Error(tokens.error_description || "トークンを取得できませんでした。");
  }
  idToken = tokens.id_token;
  history.replaceState({}, document.title, window.location.pathname);
  return true;
}

async function api(path, options = {}) {
  const headers = { Authorization: idToken, ...(options.headers || {}) };
  if (options.body) headers["Content-Type"] = "application/json";
  const result = await fetch(`${CONFIG.apiUrl}${path}`, { ...options, headers });
  const body = await result.json().catch(() => ({}));
  if (!result.ok) throw new Error(body.message || `API error (${result.status})`);
  return body;
}

function showApplication() {
  loginPanel.hidden = true;
  appPanel.hidden = false;
  document.querySelector("#sign-out").hidden = false;
}

function itemTitle(item) {
  if (item.data && typeof item.data === "object" && item.data.title) return String(item.data.title);
  return JSON.stringify(item.data);
}

function renderItems(items) {
  itemsNode.replaceChildren();
  if (items.length === 0) {
    const empty = document.createElement("div");
    empty.className = "panel muted";
    empty.textContent = "アイテムはありません。JSON を登録してください。";
    itemsNode.append(empty);
    return;
  }

  for (const item of items) {
    const card = document.createElement("article");
    card.className = "item-card";
    const summary = document.createElement("div");
    const title = document.createElement("h3");
    title.textContent = itemTitle(item);
    const id = document.createElement("p");
    id.textContent = item.id;
    summary.append(title, id);

    const actions = document.createElement("div");
    actions.className = "item-actions";
    const readButton = document.createElement("button");
    readButton.className = "button button-quiet";
    readButton.textContent = "詳細";
    readButton.addEventListener("click", () => loadItem(item.id));
    const deleteButton = document.createElement("button");
    deleteButton.className = "button button-quiet";
    deleteButton.textContent = "削除";
    deleteButton.addEventListener("click", () => deleteItem(item.id));
    const editButton = document.createElement("button");
    editButton.className = "button button-quiet";
    editButton.textContent = "編集";
    editButton.addEventListener("click", () => beginEdit(item.id));
    actions.append(readButton, editButton, deleteButton);
    card.append(summary, actions);
    itemsNode.append(card);
  }
}

async function loadItems(cursor = null) {
  setStatus("一覧を読み込んでいます…");
  const params = new URLSearchParams({ limit: "25" });
  if (cursor) params.set("nextToken", cursor);
  try {
    const result = await api(`/items?${params}`);
    activeCursor = cursor;
    renderItems(result.items || []);
    document.querySelector("#previous-page").hidden = previousCursors.length === 0;
    const nextButton = document.querySelector("#next-page");
    nextButton.hidden = !result.nextToken;
    nextButton.dataset.cursor = result.nextToken || "";
    setStatus(`${result.items.length} 件を表示しています。`);
  } catch (error) {
    setStatus(error.message, "error");
  }
}

async function loadItem(itemId) {
  try {
    const item = await api(`/items/${encodeURIComponent(itemId)}`);
    const detail = document.querySelector("#item-detail");
    detail.textContent = JSON.stringify(item, null, 2);
    detail.hidden = false;
    document.querySelector("#item-id").value = item.id;
    setStatus("アイテムを取得しました。");
  } catch (error) {
    setStatus(error.message, "error");
  }
}

async function beginEdit(itemId) {
  try {
    const item = await api(`/items/${encodeURIComponent(itemId)}`);
    editingItemId = item.id;
    document.querySelector("#item-json").value = JSON.stringify(item.data, null, 2);
    document.querySelector("#create-item").hidden = true;
    document.querySelector("#update-item").hidden = false;
    document.querySelector("#cancel-edit").hidden = false;
    setStatus(`アイテム ${item.id} を編集中です。`);
    window.scrollTo({ top: 0, behavior: "smooth" });
  } catch (error) {
    setStatus(error.message, "error");
  }
}

function cancelEdit() {
  editingItemId = null;
  document.querySelector("#create-item").hidden = false;
  document.querySelector("#update-item").hidden = true;
  document.querySelector("#cancel-edit").hidden = true;
  document.querySelector("#item-json").value = '{"title":"hello"}';
  setStatus("編集を取り消しました。");
}

async function deleteItem(itemId) {
  try {
    await api(`/items/${encodeURIComponent(itemId)}`, { method: "DELETE" });
    if (editingItemId === itemId) cancelEdit();
    document.querySelector("#item-detail").hidden = true;
    setStatus("アイテムを削除しました。");
    await loadItems(activeCursor);
  } catch (error) {
    setStatus(error.message, "error");
  }
}

document.querySelector("#login-button").addEventListener("click", async () => {
  try {
    setStatus("Cognito に接続しています…");
    await beginSignIn();
  } catch (error) {
    setStatus(error.message, "error");
  }
});

document.querySelector("#create-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  let data;
  try {
    data = JSON.parse(document.querySelector("#item-json").value);
  } catch {
    setStatus("JSON の形式を確認してください。", "error");
    return;
  }
  try {
    const item = await api("/items", { method: "POST", body: JSON.stringify(data) });
    document.querySelector("#item-id").value = item.id;
    document.querySelector("#item-detail").textContent = JSON.stringify(item, null, 2);
    document.querySelector("#item-detail").hidden = false;
    previousCursors = [];
    await loadItems();
    setStatus("アイテムを作成しました。");
  } catch (error) {
    setStatus(error.message, "error");
  }
});

document.querySelector("#update-item").addEventListener("click", async () => {
  let data;
  try {
    data = JSON.parse(document.querySelector("#item-json").value);
  } catch {
    setStatus("JSON の形式を確認してください。", "error");
    return;
  }
  try {
    const item = await api(`/items/${encodeURIComponent(editingItemId)}`, {
      method: "PUT",
      body: JSON.stringify(data),
    });
    document.querySelector("#item-detail").textContent = JSON.stringify(item, null, 2);
    document.querySelector("#item-detail").hidden = false;
    cancelEdit();
    previousCursors = [];
    await loadItems();
    setStatus("アイテムを更新しました。");
  } catch (error) {
    setStatus(error.message, "error");
  }
});

document.querySelector("#cancel-edit").addEventListener("click", cancelEdit);

document.querySelector("#get-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  await loadItem(document.querySelector("#item-id").value.trim());
});

document.querySelector("#refresh-items").addEventListener("click", () => {
  previousCursors = [];
  loadItems();
});

document.querySelector("#next-page").addEventListener("click", (event) => {
  if (event.currentTarget.dataset.cursor) {
    previousCursors.push(activeCursor);
    loadItems(event.currentTarget.dataset.cursor);
  }
});

document.querySelector("#previous-page").addEventListener("click", () => {
  loadItems(previousCursors.pop() || null);
});

document.querySelector("#sign-out").addEventListener("click", () => {
  idToken = null;
  editingItemId = null;
  const logoutUrl = new URL(`${CONFIG.cognitoDomain}/logout`);
  logoutUrl.search = new URLSearchParams({
    client_id: CONFIG.clientId,
    logout_uri: callbackUrl,
  });
  window.location.assign(logoutUrl);
});

(async () => {
  try {
    await finishSignIn();
    if (idToken) {
      showApplication();
      await loadItems();
    }
  } catch (error) {
    setStatus(error.message, "error");
  }
})();
