FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH=/srv

WORKDIR /srv

COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt \
    && rm /tmp/requirements.txt \
    && useradd --create-home --uid 10001 --shell /usr/sbin/nologin h360

COPY __init__.py app.py auth.py config.py registry.py ranker.py wording.py /srv/h360_api/
COPY routes /srv/h360_api/routes/

USER h360
EXPOSE 8090
CMD ["uvicorn", "h360_api.app:app", "--host", "0.0.0.0", "--port", "8090", "--no-access-log"]
