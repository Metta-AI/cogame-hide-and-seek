# Build Docker. ONE image, TWO entrypoints: /bin/hide-and-seek (the game
# server) and /bin/hide-and-seek-player (the thin seat registrar). The whole
# policy set is env-switched inside this same image (PLAYER_PROMPT vs
# PLAYER_SCRIPTED), which is what keeps a champion and a scripted filler
# byte-identical apart from their environment.
FROM debian:bookworm-slim AS build

RUN apt-get update && \
  apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git && \
  rm -rf /var/lib/apt/lists/*

RUN if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-X64; \
  elif [ "$(dpkg --print-architecture)" = "arm64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-ARM64; \
  else \
    echo "unsupported arch: $(dpkg --print-architecture)" && exit 1; \
  fi && \
  chmod +x /usr/local/bin/nimby && \
  nimby use 2.2.4

ENV PATH="/root/.nimby/nim/bin:$PATH"

WORKDIR /workspace/hns
COPY nimby.lock .
RUN nimby --global sync nimby.lock

COPY . .
ARG NimFlags="-d:release -d:useMalloc --opt:speed --stackTrace:on"
ARG NimCommand="c"
ARG NimMain="src/hide_and_seek.nim"
RUN nim $NimCommand \
  $NimFlags \
  --nimcache:/tmp/hns-nimcache \
  --out:hide-and-seek \
  $NimMain && \
  nim c \
  $NimFlags \
  --nimcache:/tmp/hide-and-seek-player-nimcache \
  --out:hide-and-seek-player \
  src/hide_and_seek_player.nim

# Run Docker.
FROM debian:bookworm-slim

RUN apt-get update && \
  apt-get install -y --no-install-recommends ca-certificates libcurl4 && \
  rm -rf /var/lib/apt/lists/*

WORKDIR /workspace/hns
COPY --from=build /workspace/hns/hide-and-seek /bin/hide-and-seek
COPY --from=build /workspace/hns/hide-and-seek-player /bin/hide-and-seek-player
COPY --from=build /workspace/hns/*.json ./
COPY --from=build /workspace/hns/data ./data
COPY --from=build /workspace/hns/client ./client

CMD ["/bin/hide-and-seek"]
