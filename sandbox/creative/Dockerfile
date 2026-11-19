FROM python:3.11-slim
RUN apt-get update && apt-get install -y --no-install-recommends libgomp1 libstdc++6 && rm -rf /var/lib/apt/lists/*
COPY requirements.txt /requirements.txt
RUN pip install --no-cache-dir --only-binary=:all: -r /requirements.txt
ENV HF_HUB_DISABLE_TELEMETRY=1 HF_HUB_DISABLE_XET=1 PYTHONDONTWRITEBYTECODE=1
WORKDIR /adapter
ENTRYPOINT ["python","/adapter/creative.py"]
