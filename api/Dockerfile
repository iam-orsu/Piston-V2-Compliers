FROM buildpack-deps:buster AS isolate
# buildpack-deps already includes curl — no git required.
# The tarball is pinned to the exact commit hash so the build is fully reproducible.
# This is a build-time-only download; the running container makes no outbound calls.
RUN apt-get update && \
    apt-get install -y --no-install-recommends libcap-dev && \
    rm -rf /var/lib/apt/lists/* && \
    mkdir -p /tmp/isolate && \
    curl -fsSL "https://github.com/envicutor/isolate/archive/af6db68042c3aa0ded80787fbb78bc0846ea2114.tar.gz" \
        | tar xz --strip-components=1 -C /tmp/isolate && \
    cd /tmp/isolate && \
    make -j$(nproc) install && \
    rm -rf /tmp/*

# H9: Upgraded from EOL node:15-buster-slim to node:20-bookworm-slim
FROM node:20-bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN dpkg-reconfigure -p critical dash
RUN apt-get update && \
    apt-get install -y libxml2 gnupg tar coreutils util-linux libc6-dev \
    binutils build-essential locales libpcre3-dev libevent-dev libgmp3-dev \
    libncurses6 libncurses5 libedit-dev libseccomp-dev rename procps python3 \
    libreadline-dev libblas-dev liblapack-dev libpcre3-dev libarpack2-dev \
    libfftw3-dev libglpk-dev libqhull-dev libqrupdate-dev libsuitesparse-dev \
    libsundials-dev libpcre2-dev libcap-dev && \
    rm -rf /var/lib/apt/lists/*
RUN useradd -M piston
COPY --from=isolate /usr/local/bin/isolate /usr/local/bin
COPY --from=isolate /usr/local/etc/isolate /usr/local/etc/isolate

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

WORKDIR /piston_api
COPY ["package.json", "package-lock.json", "./"]
COPY vendor ./vendor
RUN npm install
COPY ./src ./src

CMD ["/piston_api/src/docker-entrypoint.sh"]
EXPOSE 2000/tcp
