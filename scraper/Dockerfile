FROM python:3.12-slim

WORKDIR /app
COPY scraper/requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r requirements.txt
COPY scraper /app/scraper
COPY LICENSE CREDITS.md /app/

USER 10001
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=3)"]
CMD ["uvicorn", "scraper.app:app", "--host", "0.0.0.0", "--port", "8000", "--no-access-log"]
