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

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod

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

RUN groupadd --gid 1000 appuser && \
    useradd --uid 1000 --gid 1000 --create-home --shell /usr/sbin/nologin appuser

COPY airscan.conf /etc/sane.d/airscan.conf

COPY --from=build --chown=appuser:appuser /app/_build/prod/rel/scanflow ./

USER appuser

ENV PHX_SERVER=true
ENV PORT=4000

CMD ["bin/scanflow", "start"]
