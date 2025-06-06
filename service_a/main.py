import httpx
from fastapi import FastAPI
from fastapi.responses import JSONResponse


app = FastAPI(
    title="Service A FastAPI Client",
    version="0.1.0",
)


@app.get("/ping")
def ping():
    return JSONResponse(
        {
            "message": "Greetings from Service A!"
        }
    )
