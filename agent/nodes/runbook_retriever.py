# =============================================================
# agent/nodes/runbook_retriever.py
# Node 2 — Retrieves the most relevant runbook via RAG.
#
# Input:  state["search_query"]
# Output: state["runbook_context"], state["runbook_source"]
#
# Uses Bedrock Titan Embeddings V2 + pgvector cosine similarity.
# =============================================================

import json
import logging
import os

import boto3
import psycopg2
from agent.state import AgentState

logger = logging.getLogger(__name__)

AWS_REGION  = os.getenv("AWS_REGION", "ap-south-1")
EMBED_MODEL = "amazon.titan-embed-text-v2:0"
TOP_K       = 3

PG_HOST     = os.getenv("PG_HOST", "pgvector.sre-ai-agent-llm.svc.cluster.local")
PG_PORT     = int(os.getenv("PG_PORT", "5432"))
PG_DB       = os.getenv("PG_DB", "sre_agent")
PG_USER     = os.getenv("PG_USER", "postgres")
PG_PASSWORD = os.environ["PG_PASSWORD"]

MIN_SIMILARITY_THRESHOLD = 0.50

_bedrock = None
_db_conn = None


def get_bedrock():
    global _bedrock
    if _bedrock is None:
        _bedrock = boto3.client("bedrock-runtime", region_name=AWS_REGION)
    return _bedrock


def get_db():
    global _db_conn
    if _db_conn is None or _db_conn.closed:
        _db_conn = psycopg2.connect(
            host=PG_HOST, port=PG_PORT, dbname=PG_DB,
            user=PG_USER, password=PG_PASSWORD,
            connect_timeout=5,
        )
    return _db_conn


def embed(text: str) -> list[float]:
    body = json.dumps({"inputText": text, "dimensions": 1024, "normalize": True})
    resp = get_bedrock().invoke_model(
        modelId=EMBED_MODEL,
        contentType="application/json",
        accept="application/json",
        body=body,
    )
    return json.loads(resp["body"].read())["embedding"]


def retrieve_runbook(state: AgentState) -> AgentState:
    """
    LangGraph Node 2 — Runbook Retriever.

    Reads:  state["search_query"]
    Writes: state["runbook_context"], state["runbook_source"]
    """
    search_query = state["search_query"]
    logger.info(f"[Node 2] Retrieving runbook for query: '{search_query[:60]}...'")

    try:
        vector = embed(search_query)

        conn = get_db()
        cur  = conn.cursor()
        cur.execute(
            """
            SELECT title, content,
                   1 - (embedding <=> %s::vector) AS similarity
            FROM runbook_chunks
            ORDER BY embedding <=> %s::vector
            LIMIT %s
            """,
            (str(vector), str(vector), TOP_K),
        )
        rows = cur.fetchall()
        cur.close()

    except Exception as e:
        logger.error(f"[Node 2] Retrieval failed: {e}")
        return {
            **state,
            "runbook_context": "No runbook found. Use general SRE troubleshooting principles.",
            "runbook_source":  "none",
        }

    if not rows:
        logger.warning("[Node 2] No runbook chunks retrieved — using fallback context")
        return {
            **state,
            "runbook_context": "No runbook found. Use general SRE troubleshooting principles.",
            "runbook_source":  "none",
        }

    top_similarity = rows[0][2]
    if top_similarity < MIN_SIMILARITY_THRESHOLD:
        logger.warning(f"[Node 2] Low similarity score ({top_similarity:.2f})")

    context_parts = [
        f"--- Runbook: {row[0]} (similarity: {row[2]:.2f}) ---\n{row[1]}"
        for row in rows
    ]
    runbook_context = "\n\n".join(context_parts)
    runbook_source  = rows[0][0]

    logger.info(
        f"[Node 2] Retrieved {len(rows)} chunks. "
        f"Top match: {runbook_source} (similarity: {top_similarity:.4f})"
    )

    return {
        **state,
        "runbook_context": runbook_context,
        "runbook_source":  runbook_source,
    }
