# HOWTOTEST_APP

このドキュメントは、[app.py](app.py)のFlask APIをローカルで動かし、期待される出力を確認する手順をまとめたものです。

## 1. 前提

- 作業ディレクトリ: リポジトリルート
- Python実行: `uv`
- APIエンドポイント: `POST /register`

## 2. アプリの起動

以下を実行します。

```bash
uv run flask --app app run --port 5001
```

起動時に期待される出力例:

```text
 * Serving Flask app 'app'
 * Debug mode: off
WARNING: This is a development server. Do not use it in a production deployment. Use a production WSGI server instead.
 * Running on http://127.0.0.1:5001
Press CTRL+C to quit
```

## 3. 動作確認 (curl)

別ターミナルで以下を実行して確認します。

### 3-1. 正常系: 新規登録

```bash
curl -s -i -X POST http://127.0.0.1:5001/register \
  -H 'Content-Type: application/json' \
  -d '{"email":"user@example.com","password":"aaaaaaaaaaaa"}'
```

期待される出力例:

```text
HTTP/1.1 201 CREATED
...
{"message":"User registered successfully"}
```

### 3-2. 異常系: 重複メール

```bash
curl -s -i -X POST http://127.0.0.1:5001/register \
  -H 'Content-Type: application/json' \
  -d '{"email":"user@example.com","password":"aaaaaaaaaaaa"}'
```

期待される出力例:

```text
HTTP/1.1 409 CONFLICT
...
{"error":"Email already registered"}
```

### 3-3. 異常系: 不正メール形式

```bash
curl -s -i -X POST http://127.0.0.1:5001/register \
  -H 'Content-Type: application/json' \
  -d '{"email":"bad","password":"short"}'
```

期待される出力例:

```text
HTTP/1.1 400 BAD REQUEST
...
{"error":"Invalid email format"}
```

## 4. 補足: テストコードについて

テストファイルは [test_app.py](test_app.py) です。

以下のコマンドでテストを実行できます。

```bash
uv run pytest -q
```

期待される出力例:

```text
...................                                                      [100%]
19 passed in 0.06s
```
