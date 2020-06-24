FROM gitpod/workspace-full-vnc
                    
USER gitpod

RUN sudo apt-get -q update && \
    sudo apt-get install -yq grub-common qemu-system qemu-user xorriso && \
    sudo rm -rf /var/lib/apt/lists/*
