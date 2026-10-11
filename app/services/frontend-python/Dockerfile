# ---- Test ----
FROM python:3.13-slim AS test
WORKDIR /app
COPY requirements.txt requirements-dev.txt ./
RUN pip install --no-cache-dir -r requirements-dev.txt
COPY . .
RUN python -m pytest -q

# ---- Run ----
FROM python:3.13-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PORT=8080
WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt \
 && useradd --create-home --uid 10001 app
COPY --from=test /app/app.py ./
COPY --from=test /app/templates ./templates
COPY --from=test /app/static ./static
USER 10001
EXPOSE 8080
# gunicorn: production WSGI server. ONE process with 8 threads per pod: the app
# mostly waits on other services, threads handle that well, and a single process
# keeps the Prometheus counters correct. Scale out with more pods (HPA).
CMD ["sh", "-c", "exec gunicorn --bind 0.0.0.0:${PORT} --workers 1 --threads 8 --access-logfile - app:app"]
