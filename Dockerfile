FROM ubuntu:24.04

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      python3 python3-libvirt python3-fastapi python3-uvicorn python3-yaml \
      qemu-utils genisoimage \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/cloudmaker
COPY app ./app

ENV PYTHONUNBUFFERED=1 \
    LIBVIRT_URI=qemu:///system

EXPOSE 8000
CMD ["python3", "-m", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
