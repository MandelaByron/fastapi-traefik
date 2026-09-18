from fastapi import FastAPI

app = FastAPI()


@app.get("/")
async def root():
    return {"message": "Hello World, this is your King!"}


@app.get("/health")
async def health():
    return {"status": "ok"}
