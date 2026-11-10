FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg fonts-dejavu-core python3 && rm -rf /var/lib/apt/lists/*
USER 65534:65534
WORKDIR /out
ENTRYPOINT ["python3","/adapter/test_subtitles.py"]

