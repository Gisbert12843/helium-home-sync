FROM python:3.13-alpine

RUN adduser -D -u 10001 helium-home-sync && mkdir /data && chown helium-home-sync /data
WORKDIR /app
COPY server.py admin.py schema.sql ./

ENV HOST=0.0.0.0 PORT=8787 DB_PATH=/data/helium-home-sync.db
VOLUME /data
EXPOSE 8787
USER helium-home-sync

HEALTHCHECK --interval=30s --timeout=5s \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8787/api/health', timeout=4)"

CMD ["python", "-u", "server.py"]
