# Pin the toolchain and OS so an upstream floating tag cannot unexpectedly move
# the build to a new Debian release. Ubuntu Noble is supported through April 2029.
ARG ELIXIR_IMAGE=hexpm/elixir:1.19.5-erlang-28.5.0.5-ubuntu-noble-20260810

FROM ${ELIXIR_IMAGE} AS build

# Build-time dependencies for Elixir and native extensions.
RUN apt-get -o Acquire::Retries=5 update -y && \
    apt-get -o Acquire::Retries=5 install -y --no-install-recommends \
      build-essential \
      git \
      pkg-config \
      libvips-dev \
      ca-certificates && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

ENV HEX_HTTP_CONCURRENCY=1
ENV HEX_HTTP_TIMEOUT=120

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

COPY mix.exs mix.lock ./
RUN for attempt in 1 2 3; do \
      mix deps.get --only prod && exit 0; \
      echo "mix deps.get failed (attempt ${attempt}/3), retrying"; \
    done; \
    exit 1

COPY config ./config
COPY lib ./lib
COPY priv ./priv

RUN mix deps.compile && mix compile && mix release

# Runtime image intentionally keeps Elixir/Erlang installed.
FROM ${ELIXIR_IMAGE} AS app

RUN apt-get -o Acquire::Retries=5 update -y && \
    apt-get -o Acquire::Retries=5 install -y --no-install-recommends \
      ca-certificates \
      curl \
      libvips42t64 \
      poppler-utils \
      ghostscript \
      img2pdf \
      sane-airscan \
      sane-utils && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN groupadd -r appuser && \
    useradd -r -g appuser -m -s /usr/sbin/nologin appuser

COPY airscan.conf /etc/sane.d/airscan.conf

COPY --from=build --chown=appuser:appuser /app/_build/prod/rel/scanflow ./

USER appuser

ENV PHX_SERVER=true
ENV PORT=4000

CMD ["bin/scanflow", "start"]
