"""Local LLM-as-judge for `custom_response_quality` (see eval_config.yaml)."""

import os

from google import genai
from google.genai import types
from pydantic import BaseModel

# Pinned separately from the agent's MODEL on purpose: a grader that changes
# when the agent's model changes makes scores incomparable across runs. It is
# also deliberately a larger model than the agent's default.
JUDGE_MODEL = os.environ.get("JUDGE_MODEL", "gemini-3.6-flash")


class _Verdict(BaseModel):
    score: int  # 1-5
    explanation: str


def evaluate(instance):
    reference = instance.get("reference")
    rubric = (
        "Grade the agent's final response on a 1-5 scale (1 poor, 5 excellent) for "
        "accuracy, relevance, and clarity."
    )
    if reference:
        rubric += (
            " The response should agree with the expected answer below; penalize "
            "factual disagreement with it."
        )
    prompt = (
        f"You are an expert QA evaluator for an enterprise AI assistant. {rubric}\n"
        f"User Prompt: {instance.get('prompt', '')}\n"
        f"Final Response: {instance.get('response', '')}\n"
    )
    if reference:
        prompt += f"Expected Answer (ground truth): {reference}\n"
    prompt += f"Full Agent Trace: {instance.get('agent_data', '')}\n"

    client = genai.Client()  # AI Studio (GEMINI_API_KEY) or Agent Platform (ADC)
    response = client.models.generate_content(
        model=JUDGE_MODEL,
        contents=prompt,
        config=types.GenerateContentConfig(
            temperature=0,  # deterministic grading
            response_mime_type="application/json",
            response_schema=_Verdict,  # guaranteed schema-valid JSON
            # The judge declares no tools, but google-genai treats AFC as
            # enabled unless told otherwise, so it would enter the AFC path and
            # warn about function calling in a call with no functions.
            automatic_function_calling=types.AutomaticFunctionCallingConfig(
                disable=True
            ),
        ),
    )
    verdict = response.parsed
    if verdict is None:  # model returned nothing usable
        return {"score": 0, "explanation": response.text or ""}
    return {"score": max(1, min(5, verdict.score)), "explanation": verdict.explanation}
