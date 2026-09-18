from fastapi import FastAPI

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
