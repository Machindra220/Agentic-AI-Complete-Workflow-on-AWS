# =============================================================
# agent/nodes/diagnoser.py
# Node 3 — The AI reasoning step. Sends alert + runbook to
# Bedrock Claude 3 Haiku and gets a root cause diagnosis back.
#
# Input:  state["alert_parsed"], state["runbook_context"]
# Output: state["diagnosis"], state["confidence_score"]
# =============================================================

import json
import logging
import os

import boto3
from agent.state import AgentState

logger = logging.getLogger(__name__)

AWS_REGION    = os.getenv("AWS_REGION", "ap-south-1")
BEDROCK_MODEL = os.getenv("BEDROCK_MODEL_ID", "anthropic.claude-3-haiku-20240307-v1:0")

LOW_CONFIDENCE_THRESHOLD = 0.60
MAX_RETRIES = 2

SYSTEM_PROMPT = """You are a senior SRE with 10 years of experience troubleshooting
production incidents on Kubernetes and cloud platforms.
You diagnose alerts based on runbooks and return structured JSON only.
Never hallucinate — if the runbook does not have enough information,
say so in root_cause and set confidence below 0.5."""


def get_bedrock():
    return boto3.client("bedrock-runtime", region_name=AWS_REGION)


def build_diagnosis_prompt(state: AgentState) -> str:
    alert   = state["alert_parsed"]
    runbook = state["runbook_context"]

    return f"""{SYSTEM_PROMPT}

## Alert Details
- Alert Name: {alert['alert_name']}
- Severity:   {alert['severity']}
- Service:    {alert['service']}
- Type:       {alert['alert_type']}
- Message:    {alert['message']}

## Relevant Runbook Content
{runbook}

## Your Task
Based on the alert details and the runbook content above:
1. Identify the most likely root cause
2. Identify supporting evidence from the runbook
3. Suggest immediate remediation steps (include kubectl commands where applicable)
4. Rate your confidence (0.0 to 1.0) based on how well the runbook matches the alert

## Response Format
Respond ONLY with valid JSON — no preamble, no markdown, no explanation outside the JSON:

{{
    "root_cause": "One clear sentence describing the most likely root cause",
    "evidence": ["Evidence point 1 from runbook", "Evidence point 2", "Evidence point 3"],
    "immediate_steps": ["Step 1 command or action", "Step 2", "Step 3"],
    "confidence": 0.85
}}
"""


def diagnose(state: AgentState) -> AgentState:
    """
    LangGraph Node 3 — LLM Diagnoser (Bedrock Claude 3 Haiku).

    Reads:  state["alert_parsed"], state["runbook_context"], state["retry_count"]
    Writes: state["diagnosis"], state["confidence_score"]
    """
    retry = state.get("retry_count", 0)
    logger.info(f"[Node 3] Running diagnosis (attempt {retry + 1})")

    prompt = build_diagnosis_prompt(state)
    raw_response = ""

    try:
        bedrock = get_bedrock()
        body = json.dumps({
            "anthropic_version": "bedrock-2023-05-31",
            "max_tokens": 1024,
            "messages": [{"role": "user", "content": prompt}],
        })
        resp         = bedrock.invoke_model(
            modelId=BEDROCK_MODEL,
            contentType="application/json",
            accept="application/json",
            body=body,
        )
        raw_response = json.loads(resp["body"].read())["content"][0]["text"]
        logger.info(f"[Node 3] Raw LLM response: {raw_response[:200]}...")

        # Strip markdown code fences Claude sometimes adds
        clean  = raw_response.strip().replace("```json", "").replace("```", "").strip()
        result = json.loads(clean)

        root_cause      = result.get("root_cause", "Unknown root cause")
        evidence        = result.get("evidence", [])
        immediate_steps = result.get("immediate_steps", [])
        confidence      = float(result.get("confidence", 0.5))

        diagnosis = (
            f"**Root Cause:** {root_cause}\n\n"
            f"**Evidence:**\n" + "\n".join(f"- {e}" for e in evidence) + "\n\n"
            f"**Immediate Steps:**\n" + "\n".join(f"{i+1}. {s}" for i, s in enumerate(immediate_steps))
        )

        logger.info(f"[Node 3] Diagnosis complete. Confidence: {confidence:.2f}")

        return {
            **state,
            "diagnosis":        diagnosis,
            "confidence_score": confidence,
            "retry_count":      retry + 1,
        }

    except json.JSONDecodeError as e:
        logger.error(f"[Node 3] Failed to parse LLM JSON response: {e}")
        return {
            **state,
            "diagnosis":        f"Diagnosis failed — LLM returned invalid JSON: {raw_response[:200]}",
            "confidence_score": 0.0,
            "retry_count":      retry + 1,
            "error":            str(e),
        }
    except Exception as e:
        logger.error(f"[Node 3] Unexpected error during diagnosis: {e}")
        return {
            **state,
            "diagnosis":        f"Diagnosis failed — unexpected error: {str(e)}",
            "confidence_score": 0.0,
            "retry_count":      retry + 1,
            "error":            str(e),
        }


def should_retry(state: AgentState) -> str:
    """Conditional edge — returns 'retry' or 'continue'."""
    confidence  = state.get("confidence_score", 0.0)
    retry_count = state.get("retry_count", 0)
    error       = state.get("error")

    if error:
        return "continue"

    if confidence < LOW_CONFIDENCE_THRESHOLD and retry_count < MAX_RETRIES:
        logger.info(
            f"[Node 3] Low confidence ({confidence:.2f}) — retrying "
            f"(attempt {retry_count + 1}/{MAX_RETRIES})"
        )
        return "retry"

    return "continue"
