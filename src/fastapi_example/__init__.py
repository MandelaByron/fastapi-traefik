import time

import httpx
from fastapi import FastAPI
from fastapi.responses import JSONResponse
import os

app = FastAPI()


@app.get("/")
async def root():
    return {"message": "Hello World, this is your King and Queen!"}


@app.get("/love")
async def love():
    return {"message": "We love Bob Marley"}


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.get("/api/heavy")
async def heavy_endpoint():
    """
    Deliberately slow/expensive endpoint: fetches ~5000 records from a
    public API on every call. Used to demonstrate Souin caching — the
    fetch_seconds value should only change on a real (uncached) hit.
    """
    start = time.time()
    async with httpx.AsyncClient() as client:
        resp = await client.get("https://jsonplaceholder.typicode.com/photos")
        data = resp.json()
    elapsed = time.time() - start

    return JSONResponse(
        content={
            "record_count": len(data),
            "fetch_seconds": round(elapsed, 3),
            "sample": data[:3],
        },
        # Souin respects standard Cache-Control. max-age=30 tells it this
        # response is cacheable for 30 seconds.
        headers={"Cache-Control": "max-age=30"},
    )
