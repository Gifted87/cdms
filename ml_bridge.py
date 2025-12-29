import logging
from typing import Dict, Any, Optional
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field
from sentence_transformers import SentenceTransformer, util
import uvicorn
import torch

# Configuration
MODEL_NAME = "all-MiniLM-L6-v2"
PORT = 5000

# Logging Setup
logging.basicConfig(
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    level=logging.INFO
)
logger = logging.getLogger("ML_Bridge")

app = FastAPI()

# Global State
model = None
salience_anchors = None

class EmbeddingRequest(BaseModel):
    text: str
    model_version: Optional[str] = None

class SalienceRequest(BaseModel):
    text: str
    provenance: Dict[str, Any] = Field(default_factory=dict)

@app.on_event("startup")
def load_resources():
    global model, salience_anchors
    
    logger.info(f"Loading Embedding Model: {MODEL_NAME}...")
    try:
        model = SentenceTransformer(MODEL_NAME)
        
        # Pre-compute embeddings for "High Importance" concepts
        anchor_texts = [
            "Critical system failure",
            "Emergency alert security breach",
            "Major scientific discovery",
            "Vital operational data",
            "High priority task",
            "Fatal error exception"
        ]
        salience_anchors = model.encode(anchor_texts, convert_to_tensor=True)
        
        logger.info("Model and Salience Anchors Loaded. Bridge Ready.")
    except Exception as e:
        logger.critical(f"Failed to load model: {e}")
        raise e

# ------------------------------------------------------------------------------
# 1. Health Check
# ------------------------------------------------------------------------------
@app.get("/api/v1/health")
def health_check():
    """
    Used by Elixir CMS to verify the bridge is up and the model is loaded.
    """
    if model is not None:
        return {"status": "ok", "model": MODEL_NAME}
    else:
        raise HTTPException(status_code=503, detail="Model not initialized")

# ------------------------------------------------------------------------------
# 2. Vector Embedding
# ------------------------------------------------------------------------------
@app.post("/api/v1/embed")
def generate_embedding(req: EmbeddingRequest):
    if model is None:
        raise HTTPException(status_code=503, detail="Model not loaded")
        
    try:
        # Generate embedding
        embedding = model.encode(req.text)
        return {"vector": embedding.tolist()}
    except Exception as e:
        logger.error(f"Embedding failed: {str(e)}")
        raise HTTPException(status_code=500, detail=str(e))

# ------------------------------------------------------------------------------
# 3. Semantic Salience (Importance Scoring)
# ------------------------------------------------------------------------------
@app.post("/api/v1/salience")
def calculate_salience(req: SalienceRequest):
    """
    Calculates importance score (0.0 to 1.0) based on:
    1. Semantic similarity to critical concepts.
    2. Provenance priority metadata.
    """
    if model is None:
        raise HTTPException(status_code=503, detail="Model not loaded")

    try:
        # 1. Calculate Semantic Score (Zero-Shot)
        input_vec = model.encode(req.text, convert_to_tensor=True)

        # Ensure salience_anchors is loaded
        if salience_anchors is None:
            raise HTTPException(status_code=503, detail="Salience anchors not loaded")
        
        # Calculate cosine similarity against all anchors
        cosine_scores = util.cos_sim(input_vec, salience_anchors)
        
        # Take the maximum similarity as the base score
        semantic_score = float(torch.max(cosine_scores))
        
        # Normalize: Semantic similarity can be low even for matches.
        # We scale it slightly to make it more usable as a 0-1 probability.
        semantic_score = min(1.0, max(0.0, semantic_score * 1.5))

        # 2. Adjust based on Provenance (Explicit Priority)
        # Using .get() on the dictionary is safe here
        priority = req.provenance.get("priority", "normal")
        priority_boost = 0.0
        
        if priority == "critical":
            priority_boost = 0.4
        elif priority == "high":
            priority_boost = 0.2
        elif priority == "low":
            priority_boost = -0.2

        final_score = min(1.0, max(0.0, semantic_score + priority_boost))

        logger.info(f"Salience Calc: '{req.text[:20]}...' -> Semantic: {semantic_score:.2f} + Boost: {priority_boost} = {final_score:.2f}")

        return {"score": final_score}

    except Exception as e:
        logger.error(f"Salience calculation failed: {str(e)}")
        # Fallback to neutral score on error to prevent ingestion blocking
        return {"score": 0.5}

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=PORT)