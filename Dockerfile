FROM fedora:34

RUN mkdir -p /installer/downloaded \
 && dnf -y install \
    gpg2 \
    ansible \
    python3-pip

WORKDIR /installer

COPY \
    LICENSE \
    inventory \
    roles \
    install.yml \
    ansible.cfg \
    requirements.txt \
    requirements.yml \
    /installer/

RUN pip3 install -r requirements.txt \
 && ansible-galaxy collection install -r requirements.yml
ENTRYPOINT ["ansible-playbook"]
CMD ["install.yml"]
