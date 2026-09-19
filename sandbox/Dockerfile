FROM alpine:3.19

RUN apk add --no-cache \
    bash \
    coreutils \
    util-linux \
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
    musl-dev \
    make \
    nodejs \
    openjdk21-jdk \
    diffutils \
    tree

# No curl, wget, nc, nmap, netstat — no network tools at all

RUN adduser -D -u 1000 -s /bin/bash -h /home/sandbox sandbox

# /etc/skel .bashrc — copied into tmpfs home at container start
RUN mkdir -p /etc/skel && \
    printf '#!/bin/bash\nexport PS1="\\[\\033[01;32m\\]sandbox\\[\\033[00m\\]:\\[\\033[01;34m\\]\\w\\[\\033[00m\\]\\$ "\nexport TERM=xterm-256color\nalias ll="ls -la --color=auto"\nalias ls="ls --color=auto"\nalias py="python3"\n' > /etc/skel/.bashrc && \
    printf '[ -f ~/.bashrc ] && source ~/.bashrc\n' > /etc/skel/.bash_profile

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER sandbox
WORKDIR /home/sandbox
ENTRYPOINT ["/entrypoint.sh"]
CMD ["/bin/bash", "--login"]
