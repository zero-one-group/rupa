# bench/xlang/Dockerfile — one image, five runtimes, one table.
#
#     docker build -t rupa-xlang -f bench/xlang/Dockerfile .
#     docker run --rm rupa-xlang
#
# Built from the repository root, because Rupa's own column runs against the working tree
# rather than against a published version.
#
# Every version here is pinned. A comparison whose numbers cannot be reproduced is an opinion,
# and the README publishes these with a machine and a date beside them for the same reason.

FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    ELIXIR_ERL_OPTIONS="+fnu"

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl unzip git build-essential \
      python3 python3-pip \
      libssl-dev libncurses-dev \
      default-jdk-headless rlwrap \
    && rm -rf /var/lib/apt/lists/*

# ---- Erlang/OTP and Elixir, the pair .tool-versions names ---------------------------------
ARG OTP_VERSION=27.3.4
ARG ELIXIR_VERSION=1.20.3

RUN curl -sSL -o /tmp/otp.tar.gz \
      "https://github.com/erlang/otp/releases/download/OTP-${OTP_VERSION}/otp_src_${OTP_VERSION}.tar.gz" \
 && mkdir -p /tmp/otpsrc && tar xzf /tmp/otp.tar.gz -C /tmp/otpsrc --strip-components=1 \
 && cd /tmp/otpsrc && ERL_TOP=/tmp/otpsrc ./configure --prefix=/opt/otp \
      --without-wx --without-javac --without-odbc --without-debugger \
      --without-observer --without-et --without-megaco --without-jinterface --disable-sctp \
 && make -j"$(nproc)" && make install && rm -rf /tmp/otpsrc /tmp/otp.tar.gz

RUN curl -sSL -o /tmp/elixir.zip \
      "https://github.com/elixir-lang/elixir/releases/download/v${ELIXIR_VERSION}/elixir-otp-27.zip" \
 && unzip -q -o /tmp/elixir.zip -d /opt/elixir && rm /tmp/elixir.zip

ENV PATH=/opt/elixir/bin:/opt/otp/bin:$PATH

# ---- Rust ----------------------------------------------------------------------------------
# rustup picks its own target triple, so this needs no help.
ARG RUST_VERSION=1.95.0
RUN curl -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain "${RUST_VERSION}" --profile minimal
ENV PATH=/root/.cargo/bin:$PATH
RUN rustc --version

# ---- Node ----------------------------------------------------------------------------------
# Node ships a tarball per architecture and this is the one place in the file that has to know
# which. Hardcoding `linux-x64` builds fine on an arm64 host and then fails at the first `npm`,
# with a Rosetta error about a missing `/lib64/ld-linux-x86-64.so.2` -- an x86-64 binary in an
# arm64 image, named nowhere near where it was installed. `node --version` on the end of this
# layer is what turns that into a failure here instead.
ARG NODE_VERSION=22.22.2
RUN set -eu; \
    case "$(dpkg --print-architecture)" in \
      amd64) node_arch=x64 ;; \
      arm64) node_arch=arm64 ;; \
      *) echo "no Node tarball for $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    curl -sSL -o /tmp/node.tar.xz \
      "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${node_arch}.tar.xz"; \
    tar xJf /tmp/node.tar.xz -C /opt; \
    rm /tmp/node.tar.xz; \
    ln -s "/opt/node-v${NODE_VERSION}-linux-${node_arch}/bin/node" /usr/local/bin/node; \
    ln -s "/opt/node-v${NODE_VERSION}-linux-${node_arch}/bin/npm" /usr/local/bin/npm; \
    node --version

# ---- Clojure -------------------------------------------------------------------------------
# The installer is a shell script over a JVM, so it is the JDK apt gave us that decides the
# architecture, and there is nothing to choose here.
ARG CLOJURE_VERSION=1.12.0.1530
RUN curl -sSL -o /tmp/clojure.sh \
      "https://github.com/clojure/brew-install/releases/download/${CLOJURE_VERSION}/linux-install.sh" \
 && chmod +x /tmp/clojure.sh && /tmp/clojure.sh && rm /tmp/clojure.sh \
 && clojure --version

# ---- pydantic ------------------------------------------------------------------------------
ARG PYDANTIC_VERSION=2.13.3
RUN pip3 install --break-system-packages --no-cache-dir "pydantic==${PYDANTIC_VERSION}" \
 && python3 -c "import pydantic_core; print(pydantic_core.__version__)"

WORKDIR /repo
COPY . /repo/

# Fetched at build time so `docker run` is measurement and not downloading, and one step each so
# a failure names the toolchain that had it. Rupa's own column needs nothing here: the library
# has no required dependencies, so `run.sh` compiles lib/ with elixirc and runs it -- no Hex and
# no `mix deps.get`.
RUN cd /repo/bench/xlang/js && npm ci --no-audit --no-fund
RUN cd /repo/bench/xlang/rust && cargo build --release
RUN cd /repo/bench/xlang/clojure && clojure -P

# Invoked through bash rather than executed, so the image does not depend on the mode bit
# surviving whatever copied the repo in.
ENTRYPOINT ["bash", "/repo/bench/xlang/run.sh"]
