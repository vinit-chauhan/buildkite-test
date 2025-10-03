# Dockerfile
FROM buildkite/agent:3-ubuntu

# Install yq (mikefarah’s Go-based binary)
RUN apt-get update -y && apt-get install -y curl sudo python3-semver \
 && curl -L https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 \
    -o /usr/local/bin/yq \
 && chmod +x /usr/local/bin/yq \
 && rm -rf /var/lib/apt/lists/*
