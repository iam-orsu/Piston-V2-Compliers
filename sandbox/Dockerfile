FROM debian:12-slim

# glibc — C programs flush stdout before scanf() blocks, matching textbook behaviour.
# Alpine's musl does NOT do this, causing prompts to appear after user input.
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    coreutils \
    grep \
    sed \
    gawk \
    findutils \
    file \
    less \
    vim \
    nano \
    python3 \
    gcc \
    libc6-dev \
    make \
    nodejs \
    default-jdk \
    diffutils \
    tree \
    && rm -rf /var/lib/apt/lists/*

# No curl, wget, nc, nmap, netstat — no network tools at all

RUN useradd -m -u 1000 -s /bin/bash sandbox

# /etc/skel .bashrc — copied into tmpfs home at container start
RUN printf '#!/bin/bash\nexport PS1="\\[\\033[01;32m\\]sandbox\\[\\033[00m\\]:\\[\\033[01;34m\\]\\w\\[\\033[00m\\]\\$ "\nexport TERM=xterm-256color\nalias ll="ls -la --color=auto"\nalias ls="ls --color=auto"\nalias py="python3"\n' > /etc/skel/.bashrc && \
    printf '[ -f ~/.bashrc ] && source ~/.bashrc\n' > /etc/skel/.bash_profile

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER sandbox
WORKDIR /home/sandbox
ENTRYPOINT ["/entrypoint.sh"]
CMD ["/bin/bash", "--login"]
