FROM python:3.12-slim

WORKDIR /app


COPY requirements.txt ./

#RUN pip install --no-cache-dir -r requirements.txt
RUN pip install --no-cache-dir --upgrade -r requirements.txt

COPY . ./

EXPOSE 8000

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD python -c "import httpx; httpx.get('http://localhost:8000/health')" || exit 1

CMD ["fastapi", "run", "--host", "0.0.0.0", "--port", "8000", "src/fastapi_example"]