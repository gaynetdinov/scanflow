FROM elixir:1.19-slim AS build

# Build-time dependencies for Elixir, Erlang NIFs, and PDF/image tooling.
RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
      build-essential \
      git \
      pkg-config \
      libvips-dev \
      poppler-utils \
      img2pdf \
      sane-utils \
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
FROM elixir:1.19-slim AS app

RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      libvips \
      poppler-utils \
      img2pdf \
      sane-utils && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN groupadd --gid 1000 appuser && \
    useradd --uid 1000 --gid 1000 --create-home --shell /usr/sbin/nologin appuser

COPY --from=build --chown=appuser:appuser /app/_build/prod/rel/scanflow ./

USER appuser

ENV PHX_SERVER=true
ENV PORT=4000

CMD ["bin/scanflow", "start"]
