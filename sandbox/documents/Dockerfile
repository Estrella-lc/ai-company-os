FROM python:3.12-slim-bookworm
COPY requirements.lock /tmp/requirements.lock
RUN pip install --no-cache-dir --only-binary=:all: --require-hashes -r /tmp/requirements.lock
ENV PYTHONDONTWRITEBYTECODE=1
USER 65534:65534
WORKDIR /tmp
ENTRYPOINT ["python", "/adapter/documents.py"]
