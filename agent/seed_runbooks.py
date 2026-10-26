"""
Phase 2 — Seed SRE runbooks into pgvector.

Reads markdown runbooks from agent/runbooks/, generates embeddings
via Amazon Bedrock Titan Embeddings v2, and stores them in pgvector.

Prerequisites:
  pip install psycopg2-binary boto3
  kubectl port-forward -n sre-ai-agent-llm svc/pgvector 5432:5432 &

Run:
  python3 agent/seed_runbooks.py
"""

import os
import sys
import json
import glob
import boto3
import psycopg2

# ── Config ────────────────────────────────────────────────────
REGION        = os.getenv("AWS_REGION", "ap-south-1")
PG_HOST       = os.getenv("PG_HOST", "localhost")
PG_PORT       = int(os.getenv("PG_PORT", "15432"))
PG_DB         = os.getenv("PG_DB", "sre_agent")
PG_USER       = os.getenv("PG_USER", "postgres")
PG_PASSWORD   = os.environ["PG_PASSWORD"]  # required — set in .env
EMBED_MODEL   = "amazon.titan-embed-text-v2:0"
RUNBOOKS_DIR  = os.path.join(os.path.dirname(__file__), "..", "docs", "runbooks")
CHUNK_SIZE    = 500  # characters per chunk


def get_bedrock_client():
    return boto3.client("bedrock-runtime", region_name=REGION)


def embed(client, text: str) -> list[float]:
    """Generate embedding vector via Bedrock Titan Embeddings v2."""
    body = json.dumps({"inputText": text, "dimensions": 1024, "normalize": True})
    response = client.invoke_model(
        modelId=EMBED_MODEL,
        contentType="application/json",
        accept="application/json",
        body=body,
    )
    return json.loads(response["body"].read())["embedding"]


def chunk_text(text: str, size: int = CHUNK_SIZE) -> list[str]:
    """Split text into overlapping chunks (50-char overlap)."""
    chunks, start = [], 0
    while start < len(text):
        end = min(start + size, len(text))
        chunks.append(text[start:end].strip())
        start += size - 50
    return [c for c in chunks if len(c) > 50]


def main():
    runbook_files = sorted(glob.glob(os.path.join(RUNBOOKS_DIR, "*.md")))
    if not runbook_files:
        print(f"No runbooks found in {RUNBOOKS_DIR}")
        sys.exit(1)
    print(f"Found {len(runbook_files)} runbook files")

    bedrock = get_bedrock_client()

    conn = psycopg2.connect(
        host=PG_HOST, port=PG_PORT, dbname=PG_DB,
        user=PG_USER, password=PG_PASSWORD
    )
    cur = conn.cursor()

    total = 0
    for path in runbook_files:
        title = os.path.splitext(os.path.basename(path))[0]
        with open(path, "r", encoding="utf-8") as f:
            content = f.read()

        chunks = chunk_text(content)
        print(f"  {title}: {len(chunks)} chunks", end="", flush=True)

        for chunk in chunks:
            vector = embed(bedrock, chunk)
            cur.execute(
                """
                INSERT INTO runbook_chunks (title, content, embedding)
                VALUES (%s, %s, %s::vector)
                ON CONFLICT DO NOTHING
                """,
                (title, chunk, str(vector)),
            )
            total += 1
            print(".", end="", flush=True)
        print()

    conn.commit()
    cur.close()
    conn.close()
    print(f"\n✓ Seeded {total} chunks from {len(runbook_files)} runbooks")


if __name__ == "__main__":
    main()
